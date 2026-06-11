import Foundation
import Network
import Combine
import QuartzCore
import CoreMedia

class StreamManager: NSObject, ObservableObject {
    static let shared = StreamManager()

    @Published var isServerRunning = false
    @Published var isClientConnected = false
    @Published var clientIp: String?
    @Published var transportMode = "UDP"
    @Published var streamUrl = ""
    @Published var currentFps = 0.0
    @Published var perfStatus = ""

    let cameraManager = CameraManager()
    private var rtspServer: SimpleRTSPServer?

    private let videoEncoder = H264Encoder()
    private let audioEncoder = AudioEncoder()

    let videoFrameProvider = VideoFrameProvider()
    let audioFrameProvider = AudioFrameProvider()
    let perfMonitor = PerformanceMonitor()
    
    private var videoSender: RTPSender?
    private var audioSender: RTPSender?
    
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

        // Handle encoded video frames — send only when a client is connected
        videoEncoder.setCallback { [weak self] data, isKeyFrame, timestampUs in
            guard let self = self else { return }
            self.videoSender?.sendVideoFrame(data: data, timestampUs: timestampUs, isKeyFrame: isKeyFrame)
        }

        // Handle encoded audio frames — send only when a client is connected
        audioEncoder.setCallback { [weak self] data, timestampUs in
            guard let self = self else { return }
            self.audioSender?.sendAudioFrame(data: data, timestampUs: timestampUs)
        }
    }
    
    func startServer() {
        guard !isServerRunning else { return }

        let settings = SettingsManager.shared
        let ip = Utils.getIPAddress()
        streamUrl = "rtsp://\(ip):\(settings.rtspPort)\(settings.rtspPath)"

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
                self?.clientIp = ip
                self?.isClientConnected = (ip != nil)
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
    
    func stopServer() {
        guard isServerRunning else { return }

        rtspServer?.stop()
        rtspServer = nil
        isServerRunning = false

        // Stop senders
        videoSender?.stop()
        videoSender = nil
        audioSender?.stop()
        audioSender = nil

        // Stop encoders (only when server fully stops, not on client disconnect)
        videoEncoder.stop()
        audioEncoder.stop()

        stopFpsMonitor()
        cameraManager.stop()

        streamUrl = ""
    }
    
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

        DispatchQueue.main.async {
            self.transportMode = isTcp ? "TCP" : "UDP"
        }

        // Encoder is already configured and running from startServer().
        // Only create RTP senders for the connected client.
        videoSender = RTPSender(
            clientHost: clientHost,
            clientPort: videoPort,
            codec: settings.videoCodec,
            isTcp: isTcp,
            tcpConnection: connection,
            tcpChannel: videoCh,
            clockRate: 90000,
            getSps: { [weak self] in self?.videoEncoder.sps },
            getPps: { [weak self] in self?.videoEncoder.pps },
            getVps: { [weak self] in self?.videoEncoder.vps }
        )
        videoSender?.start()

        if settings.audioEnabled {
            audioSender = RTPSender(
                clientHost: clientHost,
                clientPort: audioPort,
                codec: "aac",
                isTcp: isTcp,
                tcpConnection: connection,
                tcpChannel: audioCh,
                clockRate: 44100
            )
            audioSender?.start()
        }

        // Update FPS diagnostics
        startFpsMonitor()
    }
    
    private func stopStreaming() {
        // Only stop senders — keep encoder running so SPS/PPS remain available
        // for the next client connection. Encoder is stopped in stopServer().
        videoSender?.stop()
        videoSender = nil

        audioSender?.stop()
        audioSender = nil

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
        perfStatus = perfMonitor.getStatusText()
    }
}
