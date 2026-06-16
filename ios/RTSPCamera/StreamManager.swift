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
        var encFrameCount = 0
        videoEncoder.setCallback { [weak self] data, isKeyFrame, timestampUs in
            guard let self = self else { return }
            encFrameCount += 1
            if encFrameCount <= 3 || encFrameCount % 90 == 0 {
                print("[RTSPCamera] Encoder callback: frame #\(encFrameCount), size=\(data.count)B, keyframe=\(isKeyFrame), serverRunning=\(self.isServerRunning)")
            }

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
                frame.isKeyFrame = isKeyFrame
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

                // Keep the red warning border visible the entire time a previously
                // connected client is gone (matching Android), and clear it as soon as a
                // new client connects. Previously this only flashed for 2 seconds.
                if wasConnected && ip == nil {
                    self?.clientDisconnected = true
                } else if ip != nil {
                    self?.clientDisconnected = false
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

        // Pre-allocate the video frame pool up-front so the VideoToolbox callback
        // thread never blocks on first-frame allocation (matches Android's H264FrameProvider).
        videoFrameProvider.prepare()

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

        // --- Immediate UI state update (main thread) ---
        // Explicitly clear client-connected state BEFORE tearing down the server.
        // stop() → close() → connection.cancel() triggers async handleDisconnect()
        // which calls clearSession() → onClientChange?(nil). But we are about to
        // null out rtspServer, and the session only has a weak ref to it — if the
        // weak ref goes nil before the async callback fires, isClientConnected
        // never gets cleared and the RES dropdown stays disabled forever.
        isClientConnected = false
        clientIp = nil
        rtspServer?.stop()
        rtspServer = nil
        isServerRunning = false
        clientDisconnected = false
        streamUrl = ""

        // Stop senders — signals semaphores so blocked reader threads can unblock
        videoSender?.stop()
        videoSender = nil
        audioSender?.stop()
        audioSender = nil

        // Cancel frame readers
        videoReaderCancellation?.cancelled = true
        videoFrameReadTask?.cancel()
        videoFrameReadTask = nil
        audioReaderCancellation?.cancelled = true
        audioFrameReadTask?.cancel()
        audioFrameReadTask = nil

        // --- Heavy cleanup off main thread ---
        // VTCompressionSessionInvalidate, camera reconfiguration and encoder teardown
        // can block for hundreds of ms if VideoToolbox callbacks are in flight.
        // Doing this here keeps the UI responsive the instant user taps Stop.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            self.videoEncoder.stop()
            self.audioEncoder.stop()

            self.videoFrameProvider.clear()
            self.audioFrameProvider.clear()

            self.stopFpsMonitor()

            let settings = SettingsManager.shared
            self.cameraManager.configureSession(
                width: settings.getWidth(),
                height: settings.getHeight(),
                fps: settings.fps,
                audioEnabled: false
            )
            self.cameraManager.start()

            print("[RTSPCamera] stopServer background cleanup complete")
        }
    }
    
    private var videoFrameReadTask: DispatchWorkItem?
    private var audioFrameReadTask: DispatchWorkItem?
    /// Reference-type cancellation flag shared between the StreamManager and the
    /// frame-reader closures. Setting `cancelled = true` from stopStreaming() lets
    /// the reader loops break out within one getFrameBlocking() timeout window.
    /// We use a class (reference type) so the closure captures the same instance,
    /// avoiding "captures 'task' before it is declared" errors when a DispatchWorkItem
    /// closure would otherwise need to reference its own `task` constant.
    private final class ReaderCancellation {
        var cancelled: Bool = false
    }
    private var videoReaderCancellation: ReaderCancellation?
    private var audioReaderCancellation: ReaderCancellation?

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
        print("[RTSPCamera] startStreaming: scheduling frame readers with \(delayMs)ms delay")
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + .milliseconds(delayMs)) { [weak self] in
            guard let self = self else {
                print("[RTSPCamera] startStreaming: self is nil when frame reader dispatch fired")
                return
            }
            print("[RTSPCamera] startStreaming: starting video frame reader now")
            self.startVideoFrameReader()
            if settings.audioEnabled {
                self.startAudioFrameReader()
            }
        }

        // Update FPS diagnostics
        startFpsMonitor()
        print("[RTSPCamera] startStreaming: setup complete, waiting for frames")
    }
    
    private func startVideoFrameReader() {
        var localFrameCount = 0
        var lastLogTime = CACurrentMediaTime()
        let cancellation = ReaderCancellation()
        videoReaderCancellation = cancellation
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else {
                print("[RTSPCamera] VideoFrameReader: self is nil, exiting")
                return
            }
            print("[RTSPCamera] VideoFrameReader: loop starting, videoSender=\(self.videoSender != nil ? "valid" : "nil")")
            while self.videoSender != nil {
                // Cooperative cancellation: stopStreaming() sets the shared flag so the
                // loop breaks out within one getFrameBlocking() timeout window instead of
                // spinning on a stale videoSender reference across queues.
                if cancellation.cancelled { break }
                if let frame = self.videoFrameProvider.getFrameBlocking(timeoutMs: 1000) {
                    let data = Data(bytes: frame.buffer, count: frame.length)
                    let timestampUs = frame.timestampUs
                    // The encoder callback already classified this frame; reuse that flag
                    // instead of re-scanning the NAL byte stream here (saves an O(n) pass
                    // over every frame, ~45KB for a P-frame, on the reader thread).
                    let isKeyFrame = frame.isKeyFrame
                    self.videoSender?.sendVideoFrame(data: data, timestampUs: timestampUs, isKeyFrame: isKeyFrame)
                    self.sentFramesCount += 1
                    localFrameCount += 1
                    self.videoFrameProvider.recycleFrame(frame)

                    // Log first frame and then every 2 seconds
                    let now = CACurrentMediaTime()
                    if localFrameCount == 1 || now - lastLogTime >= 2.0 {
                        print("[RTSPCamera] VideoFrameReader: sent \(localFrameCount) frames total, latest size=\(data.count)B keyframe=\(isKeyFrame)")
                        lastLogTime = now
                    }
                }
            }
            print("[RTSPCamera] VideoFrameReader: loop exited (videoSender became nil)")
        }
        videoFrameReadTask = task
        DispatchQueue.global(qos: .userInitiated).async(execute: task)
    }

    private func startAudioFrameReader() {
        let cancellation = ReaderCancellation()
        audioReaderCancellation = cancellation
        let task = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            while self.audioSender != nil {
                if cancellation.cancelled { break }
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

    private func stopStreaming() {
        // Only stop senders — keep encoder running so SPS/PPS remain available
        // for the next client connection. Encoder is stopped in stopServer().
        videoSender?.stop()
        videoSender = nil

        audioSender?.stop()
        audioSender = nil

        // Stop frame readers
        videoReaderCancellation?.cancelled = true
        videoReaderCancellation = nil
        videoFrameReadTask?.cancel()
        videoFrameReadTask = nil
        audioReaderCancellation?.cancelled = true
        audioReaderCancellation = nil
        audioFrameReadTask?.cancel()
        audioFrameReadTask = nil

        stopFpsMonitor()
    }
    
    // MARK: - FPS Monitor

    private var lastFpsCheckTime: TimeInterval = 0
    private var frameCountSinceLastCheck = 0
    /// 1Hz timer for the slow-changing telemetry (CPU/NET/BAT/MEM). FPS is still updated
    /// from the CADisplayLink above, but sampling these system counters at display refresh
    /// rate (60-120Hz) made the HUD numbers flicker wildly. Android samples these once
    /// per second; we match that cadence here.
    private var perfTimer: Timer?

    private func startFpsMonitor() {
        DispatchQueue.main.async {
            self.displayLink = CADisplayLink(target: self, selector: #selector(self.displayLinkFired))
            self.displayLink?.add(to: .main, forMode: .common)
            self.lastFpsCheckTime = CACurrentMediaTime()
            // Slow telemetry: refresh once per second.
            self.perfTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
                self?.refreshSlowTelemetry()
            }
        }
    }

    private func stopFpsMonitor() {
        DispatchQueue.main.async {
            self.displayLink?.invalidate()
            self.displayLink = nil
            self.perfTimer?.invalidate()
            self.perfTimer = nil
            self.currentFps = 0.0
        }
    }

    @objc private func displayLinkFired() {
        // High-frequency: only the encoder FPS and frame counters.
        currentFps = videoEncoder.currentFps
        totalSentFrames = sentFramesCount
        totalDroppedFrames = Int64(videoFrameProvider.totalDroppedFrames)
        abrTargetBitrateMbps = Double(abrTargetBitrate) / 1000000.0

        let settings = SettingsManager.shared
        let codecStr = settings.videoCodec.uppercased()
        let resStr = settings.resolution
        let abrStr = String(format: "ABR: %.1f/%d Mbps | Loss: %.1f%%", abrTargetBitrateMbps, settings.bitrate, currentLossPercent)
        let framesStr = "Frames: Sent \(totalSentFrames) / Drop \(totalDroppedFrames)"
        let systemStr = "\(perfCpu) | \(perfMem) | \(perfNet) | \(perfBat)"
        perfStatus = "\(codecStr) \(resStr) | \(framesStr) | \(abrStr) | \(systemStr)"
    }

    /// Samples the slow-changing system counters (CPU/MEM/NET/BAT) at 1Hz so the HUD
    /// numbers stay readable instead of flickering at display-refresh rate.
    private func refreshSlowTelemetry() {
        perfCpu = perfMonitor.getAppCpuUsage()
        perfMem = perfMonitor.getMemoryUsage()
        perfNet = perfMonitor.getNetworkSpeed()
        perfBat = perfMonitor.getBatteryLevel()
    }
}
