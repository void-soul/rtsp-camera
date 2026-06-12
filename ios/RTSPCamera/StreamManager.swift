import Foundation
import Network
import Combine
import QuartzCore
import CoreMedia
import AVFoundation

class SharedStreamState {
    private var streamStartPtsUs: Int64 = -1
    private let lock = NSLock()
    
    func getOrSetStartPts(_ pts: Int64) -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if streamStartPtsUs == -1 {
            streamStartPtsUs = pts
        }
        return streamStartPtsUs
    }
    
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        streamStartPtsUs = -1
    }
}

class StreamManager: NSObject, ObservableObject {
    static let shared = StreamManager()

    @Published var isServerRunning = false
    @Published var isClientConnected = false
    @Published var clientIp: String?
    @Published var transportMode = "UDP"
    @Published var streamUrl = ""
    @Published var currentFps = 0.0
    @Published var perfStatus = ""
    @Published var clientDisconnected = false

    @Published var totalSentFrames: Int64 = 0
    @Published var totalDroppedFrames: Int64 = 0
    @Published var currentLossPercent: Double = 0.0
    @Published var abrTargetBitrateMbps: Double = 0.0
    
    @Published var perfCpu = "--"
    @Published var perfMem = "--"
    @Published var perfNet = "--"
    @Published var perfBat = "--"
    
    // Internal counters
    private(set) var sentFramesCount: Int64 = 0

    let cameraManager = CameraManager()
    private var rtspServer: SimpleRTSPServer?

    private let videoEncoder = H264Encoder()
    private let audioEncoder = AudioEncoder()

    let videoFrameProvider = VideoFrameProvider()
    let audioFrameProvider = AudioFrameProvider()
    let perfMonitor = PerformanceMonitor()
    
    private var videoSender: RTPSender?
    private var audioSender: RTPSender?
    private let sharedStreamState = SharedStreamState()
    
    private var displayLink: CADisplayLink?
    private var cancellables = Set<AnyCancellable>()
    
    override init() {
        super.init()
        setupCallbacks()
    }
    
    private func setupCallbacks() {
        // Handle video frame output from AVCaptureSession — always encode when server is running
        // to ensure SPS/PPS are available for SDP before any client connects
        cameraManager.onVideoSampleBuffer = { [weak self] sampleBuffer in
            guard let self = self, self.isServerRunning else { return }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let timestampUs = Int64(CMTimeGetSeconds(pts) * 1_000_000)

            self.videoEncoder.encode(pixelBuffer: pixelBuffer, timestampUs: timestampUs)
        }

        // Handle audio frame output from AVCaptureSession
        cameraManager.onAudioSampleBuffer = { [weak self] sampleBuffer in
            guard let self = self, self.isServerRunning else { return }
            self.audioEncoder.encode(sampleBuffer: sampleBuffer)
        }

        // Handle encoded video frames — route through frame provider for pooling and queue management
        videoEncoder.setCallback { [weak self] data, isKeyFrame, timestampUs in
            guard let self = self else { return }
            
            // Store SPS/PPS/VPS for SDP generation
            if isKeyFrame {
                let startCode = Data([0x00, 0x00, 0x00, 0x01])
                if self.videoEncoder.currentCodec.lowercased() == "h265",
                   let vps = self.videoEncoder.vps,
                   let sps = self.videoEncoder.sps,
                   let pps = self.videoEncoder.pps {
                    self.videoFrameProvider.setParameterSets(data: startCode + vps + startCode + sps + startCode + pps)
                } else if let sps = self.videoEncoder.sps,
                          let pps = self.videoEncoder.pps {
                    self.videoFrameProvider.setParameterSets(data: startCode + sps + startCode + pps)
                }
            }
            
            // Obtain a frame from the pool, copy data, and enqueue
            if let frame = self.videoFrameProvider.obtainEmptyFrame() {
                let copyLength = min(data.count, frame.capacity)
                data.copyBytes(to: frame.buffer, count: copyLength)
                frame.length = copyLength
                frame.timestampUs = timestampUs
                self.videoFrameProvider.addFrame(frame)
            }
        }

        // Handle encoded audio frames — route through frame provider for pooling
        audioEncoder.setCallback { [weak self] data, timestampUs in
            guard let self = self else { return }
            
            if let frame = self.audioFrameProvider.obtainEmptyFrame() {
                let copyLength = min(data.count, frame.capacity)
                data.copyBytes(to: frame.buffer, count: copyLength)
                frame.length = copyLength
                frame.timestampUs = timestampUs
                self.audioFrameProvider.addFrame(frame)
            }
        }
        
        // Set up keyframe requester for overflow recovery
        videoFrameProvider.keyframeRequester = { [weak self] in
            self?.videoEncoder.requestKeyframe()
        }
    }
    
    func startServer() {
        guard !isServerRunning else { return }

        let settings = SettingsManager.shared
        let ip = Utils.getIPAddress()
        streamUrl = "rtsp://\(ip):\(settings.rtspPort)\(settings.rtspPath)"
        print("[RTSPCamera] startServer called, URL: \(streamUrl)")

        rtspServer = SimpleRTSPServer(
            port: UInt16(settings.rtspPort),
            path: settings.rtspPath,
            videoCodec: settings.videoCodec,
            audioEnabled: settings.audioEnabled
        )

        rtspServer?.getSps = { [weak self] in self?.videoEncoder.sps }
        rtspServer?.getPps = { [weak self] in self?.videoEncoder.pps }
        rtspServer?.getVps = { [weak self] in self?.videoEncoder.vps }

        rtspServer?.onClientChange = { [weak self] ip in
            DispatchQueue.main.async {
                let wasConnected = self?.isClientConnected ?? false
                self?.clientIp = ip
                self?.isClientConnected = (ip != nil)
                
                // Trigger alert border when client disconnects
                if wasConnected && ip == nil {
                    self?.clientDisconnected = true
                    // Auto-hide after 2 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        self?.clientDisconnected = false
                    }
                }
            }
        }

        rtspServer?.onSessionPlay = { [weak self] clientHost, videoPort, audioPort, isTcp, connection, videoCh, audioCh in
            self?.startStreaming(
                clientHost: clientHost,
                videoPort: videoPort,
                audioPort: audioPort,
                isTcp: isTcp,
                connection: connection,
                videoCh: videoCh,
                audioCh: audioCh
            )
        }

        rtspServer?.onSessionStop = { [weak self] in
            self?.stopStreaming()
        }

        isServerRunning = true

        // Configure audio session for background playback
        configureAudioSession()

        // Start camera and configure encoder immediately so SPS/PPS are available
        // before any client connects (matches Android's approach)
        cameraManager.configureSession(
            width: settings.getWidth(),
            height: settings.getHeight(),
            fps: settings.fps,
            audioEnabled: settings.audioEnabled
        )
        cameraManager.start()

        // Configure encoder right away — frames will be encoded and SPS/PPS extracted
        // even before a client connects. RTP sending is gated on videoSender != nil.
        videoEncoder.configure(
            width: Int32(settings.getWidth()),
            height: Int32(settings.getHeight()),
            codec: settings.videoCodec,
            fps: settings.fps,
            bitrateMbps: settings.bitrate,
            gop: settings.gop
        )

        if settings.audioEnabled {
            audioEncoder.configure(
                sampleRate: 44100.0,
                channels: 1
            )
        }

        // Start RTSP server after encoder is configured
        rtspServer?.start()
    }
    
    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            // Configure for background audio playback
            try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
    
    func stopServer() {
        print("[RTSPCamera] stopServer called")
        guard isServerRunning else { return }

        rtspServer?.stop()
        rtspServer = nil
        isServerRunning = false

        // Stop senders
        videoSender?.stop()
        videoSender = nil
        audioSender?.stop()
        audioSender = nil

        // Stop frame readers
        videoFrameReadTask?.cancel()
        videoFrameReadTask = nil
        audioFrameReadTask?.cancel()
        audioFrameReadTask = nil

        // Stop encoders (only when server fully stops, not on client disconnect)
        videoEncoder.stop()
        audioEncoder.stop()

        // Clear frame providers
        videoFrameProvider.clear()
        audioFrameProvider.clear()

        stopFpsMonitor()
        cameraManager.stop()

        streamUrl = ""
    }
    
    private var videoFrameReadTask: DispatchWorkItem?
    private var audioFrameReadTask: DispatchWorkItem?
    
    // ABR (Adaptive Bitrate) state
    private var abrTargetBitrate: Int = 0
    private var abrLastLossCheckTime: TimeInterval = 0
    private var abrZeroLossDuration: TimeInterval = 0

    private func startStreaming(
        clientHost: String,
        videoPort: UInt16,
        audioPort: UInt16,
        isTcp: Bool,
        connection: NWConnection?,
        videoCh: Int,
        audioCh: Int
    ) {
        let settings = SettingsManager.shared

        print("[RTSPCamera] startStreaming called: host=\(clientHost), videoPort=\(videoPort), audioPort=\(audioPort), isTcp=\(isTcp), videoCh=\(videoCh), audioCh=\(audioCh)")

        DispatchQueue.main.async {
            self.transportMode = isTcp ? "TCP" : "UDP"
        }

        // Reset the relative timestamp start offset
        sharedStreamState.reset()

        // Clear stale frames from the queue to avoid initial latency
        videoFrameProvider.clearFilledQueue()
        audioFrameProvider.clear()

        // Encoder is already configured and running from startServer().
        // Force a keyframe so the client gets a clean starting point (SPS/PPS + IDR)
        // regardless of where we are in the GOP.
        videoEncoder.requestKeyframe()

        // Reset frame provider keyframe request state
        videoFrameProvider.resetDroppedFrameStats()

        // Reset ABR & sent counters
        sentFramesCount = 0
        currentLossPercent = 0.0
        abrTargetBitrateMbps = Double(settings.bitrate)

        // Only create RTP senders for the connected client.
        videoSender = RTPSender(
            clientHost: clientHost,
            clientPort: videoPort,
            localPort: isTcp ? nil : 50000,
            codec: settings.videoCodec,
            isTcp: isTcp,
            tcpConnection: connection,
            tcpChannel: videoCh,
            clockRate: 90000,
            sharedState: sharedStreamState,
            getSps: { [weak self] in self?.videoEncoder.sps },
            getPps: { [weak self] in self?.videoEncoder.pps },
            getVps: { [weak self] in self?.videoEncoder.vps }
        )
        videoSender?.start()
        
        // Set up ABR (Adaptive Bitrate) feedback
        abrTargetBitrate = settings.bitrate * 1000 * 1000 // Convert Mbps to bps
        abrLastLossCheckTime = CACurrentMediaTime()
        abrZeroLossDuration = 0
        setupABR()

        // Start reading video frames from the frame provider and sending via RTP
        // For TCP, we add a 100ms delay to prevent socket flooding before the client processes the PLAY response.
        if settings.audioEnabled {
            audioSender = RTPSender(
                clientHost: clientHost,
                clientPort: audioPort,
                localPort: isTcp ? nil : 50002,
                codec: "aac",
                isTcp: isTcp,
                tcpConnection: connection,
                tcpChannel: audioCh,
                clockRate: 44100,
                sharedState: sharedStreamState
            )
            audioSender?.start()
        }

        let delayMs = isTcp ? 100 : 0
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self = self else { return }
            self.startVideoFrameReader()
            if settings.audioEnabled {
                self.startAudioFrameReader()
            }
        }

        // Update FPS diagnostics
        startFpsMonitor()
    }
    
    private func startVideoFrameReader() {
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            while self.videoSender != nil {
                if let frame = self.videoFrameProvider.getFrameBlocking(timeoutMs: 1000) {
                    let data = Data(bytes: frame.buffer, count: frame.length)
                    let timestampUs = frame.timestampUs
                    let isKeyFrame = self.isKeyFrame(data: data)
                    self.videoSender?.sendVideoFrame(data: data, timestampUs: timestampUs, isKeyFrame: isKeyFrame)
                    self.sentFramesCount += 1
                    self.videoFrameProvider.recycleFrame(frame)
                }
            }
        }
        videoFrameReadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
    
    private func startAudioFrameReader() {
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            while self.audioSender != nil {
                if let frame = self.audioFrameProvider.getFrameBlocking(timeoutMs: 1000) {
                    let data = Data(bytes: frame.buffer, count: frame.length)
                    let timestampUs = frame.timestampUs
                    self.audioSender?.sendAudioFrame(data: data, timestampUs: timestampUs)
                    self.audioFrameProvider.recycleFrame(frame)
                }
            }
        }
        audioFrameReadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }
    
    private func setupABR() {
        // Wire up RTCP feedback for ABR
        videoSender?.onPacketLoss = { [weak self] fractionLost in
            self?.handlePacketLoss(fractionLost: fractionLost)
        }
    }
    
    private func handlePacketLoss(fractionLost: UInt8) {
        let now = CACurrentMediaTime()
        let elapsed = now - abrLastLossCheckTime
        abrLastLossCheckTime = now
        
        let loss = Double(fractionLost) / 256.0 * 100.0
        DispatchQueue.main.async {
            self.currentLossPercent = loss
        }
        
        if fractionLost > 12 { // ~5% loss threshold
            // Reduce bitrate to 75% of current
            let newBitrate = max(abrTargetBitrate * 75 / 100, abrTargetBitrate / 5)
            abrTargetBitrate = newBitrate
            videoEncoder.updateDynamicBitrate(bps: newBitrate)
            abrZeroLossDuration = 0
        } else {
            // No significant loss
            abrZeroLossDuration += elapsed
            if abrZeroLossDuration >= 30.0 {
                // Increase bitrate by 10% after 30 seconds of zero loss
                let maxBitrate = SettingsManager.shared.bitrate * 1000 * 1000
                let newBitrate = min(abrTargetBitrate * 110 / 100 + 1, maxBitrate)
                abrTargetBitrate = newBitrate
                videoEncoder.updateDynamicBitrate(bps: newBitrate)
                abrZeroLossDuration = 0
            }
        }
        
        DispatchQueue.main.async {
            self.abrTargetBitrateMbps = Double(self.abrTargetBitrate) / 1000000.0
        }
    }
    
    private func isKeyFrame(data: Data) -> Bool {
        // Check if the data contains an IDR NAL unit (H.264 type 5 or H.265 type 19/20/21)
        let settings = SettingsManager.shared
        let isH265 = (settings.videoCodec.lowercased() == "h265")
        
        var i = 0
        while i < data.count - 4 {
            if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
                let nalByte = data[i + 3]
                let nalType = isH265 ? ((nalByte >> 1) & 0x3F) : (nalByte & 0x1F)
                let isKey = isH265 ? (nalType >= 19 && nalType <= 21) : (nalType == 5)
                if isKey { return true }
                i += 3
            } else if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
                let nalByte = data[i + 4]
                let nalType = isH265 ? ((nalByte >> 1) & 0x3F) : (nalByte & 0x1F)
                let isKey = isH265 ? (nalType >= 19 && nalType <= 21) : (nalType == 5)
                if isKey { return true }
                i += 4
            } else {
                i += 1
            }
        }
        return false
    }
    
    private func stopStreaming() {
        // Only stop senders — keep encoder running so SPS/PPS remain available
        // for the next client connection. Encoder is stopped in stopServer().
        videoSender?.stop()
        videoSender = nil

        audioSender?.stop()
        audioSender = nil

        // Stop frame readers
        videoFrameReadTask?.cancel()
        videoFrameReadTask = nil
        audioFrameReadTask?.cancel()
        audioFrameReadTask = nil

        stopFpsMonitor()
    }
    
    // MARK: - FPS Monitor
    
    private var lastFpsCheckTime: TimeInterval = 0
    private var frameCountSinceLastCheck = 0
    
    private func startFpsMonitor() {
        DispatchQueue.main.async {
            self.displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkFired))
            self.displayLink?.add(to: .main, forMode: .common)
            self.lastFpsCheckTime = CACurrentMediaTime()
        }
    }
    
    private func stopFpsMonitor() {
        DispatchQueue.main.async {
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.currentFps = 0.0
        }
    }
    
    @objc private func displayLinkFired() {
        currentFps = videoEncoder.currentFps
        totalSentFrames = sentFramesCount
        totalDroppedFrames = Int64(videoFrameProvider.totalDroppedFrames)
        
        abrTargetBitrateMbps = Double(abrTargetBitrate) / 1000000.0
        
        perfCpu = perfMonitor.getAppCpuUsage()
        perfMem = perfMonitor.getMemoryUsage()
        perfNet = perfMonitor.getNetworkSpeed()
        perfBat = perfMonitor.getBatteryLevel()
        
        let settings = SettingsManager.shared
        let codecStr = settings.videoCodec.uppercased()
        let resStr = settings.resolution
        let abrStr = String(format: "ABR: %.1f/%d Mbps | Loss: %.1f%%", abrTargetBitrateMbps, settings.bitrate, currentLossPercent)
        let framesStr = "Frames: Sent \(totalSentFrames) / Drop \(totalDroppedFrames)"
        let systemStr = perfMonitor.getStatusText()
        perfStatus = "\(codecStr) \(resStr) | \(framesStr) | \(abrStr) | \(systemStr)"
    }
}
