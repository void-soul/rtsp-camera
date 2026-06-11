import Foundation
import AVFoundation
import UIKit

class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    @Published var isRunning = false
    @Published var activeCameraPosition: AVCaptureDevice.Position = .back
    @Published var zoomFactor: CGFloat = 1.0
    @Published var exposureBias: Float = 0.0
    @Published var isTorchOn = false
    @Published var focusMode: AVCaptureDevice.FocusMode = .continuousAutoFocus
    @Published var lensPosition: Float = 0.0 // For manual focus slider (0.0 to 1.0)
    @Published var whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode = .continuousAutoWhiteBalance
    @Published var currentWBMode: String = "AUTO"
    @Published var currentFilter: String = "None"
    @Published var isOISEnabled = true
    @Published var isEISEnabled = true
    
    let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    
    private var videoDeviceInput: AVCaptureDeviceInput?
    private var audioDeviceInput: AVCaptureDeviceInput?
    
    private let sessionQueue = DispatchQueue(label: "com.gld.rtsp_camera.sessionQueue")
    private let videoDataQueue = DispatchQueue(label: "com.gld.rtsp_camera.videoDataQueue", qos: .userInteractive)
    private let audioDataQueue = DispatchQueue(label: "com.gld.rtsp_camera.audioDataQueue", qos: .userInteractive)
    
    var onVideoSampleBuffer: ((CMSampleBuffer) -> Void)?
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?
    
    override init() {
        super.init()
        setupInterruptionNotifications()
    }
    
    func configureSession(width: Int, height: Int, fps: Int, audioEnabled: Bool) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            self.captureSession.beginConfiguration()
            
            // Re-use or clear inputs
            if let videoInput = self.videoDeviceInput {
                self.captureSession.removeInput(videoInput)
            }
            if let audioInput = self.audioDeviceInput {
                self.captureSession.removeInput(audioInput)
            }
            
            // Set preset: we try to match requested resolution
            self.setSessionPreset(width: width, height: height)
            
            // Add Video Input
            guard let videoDevice = self.findVideoDevice(for: self.activeCameraPosition) else {
                print("Could not find video device")
                self.captureSession.commitConfiguration()
                return
            }
            
            do {
                let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                if self.captureSession.canAddInput(videoInput) {
                    self.captureSession.addInput(videoInput)
                    self.videoDeviceInput = videoInput
                }
            } catch {
                print("Could not create video input: \(error)")
            }
            
            // Set Frame Rate (FPS) — must match resolution to avoid overriding session preset
            self.configureFPS(device: videoDevice, targetWidth: width, targetHeight: height, fps: fps)
            
            // Add Audio Input if enabled
            if audioEnabled {
                if let audioDevice = AVCaptureDevice.default(for: .audio) {
                    do {
                        let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                        if self.captureSession.canAddInput(audioInput) {
                            self.captureSession.addInput(audioInput)
                            self.audioDeviceInput = audioInput
                        }
                    } catch {
                        print("Could not create audio input: \(error)")
                    }
                }
            }
            
            // Configure Video Output
            self.captureSession.removeOutput(self.videoOutput)
            self.videoOutput.alwaysDiscardsLateVideoFrames = true
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
            self.videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) // NV12 matching Android
            ]
            if self.captureSession.canAddOutput(self.videoOutput) {
                self.captureSession.addOutput(self.videoOutput)
            }
            
            // Configure stabilization (OIS/EIS) & Orientation
            if let connection = self.videoOutput.connection(with: .video) {
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                }
                connection.videoOrientation = .landscapeRight // Match Android landscape layout
            }
            
            // Configure Audio Output
            self.captureSession.removeOutput(self.audioOutput)
            if audioEnabled {
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioDataQueue)
                if self.captureSession.canAddOutput(self.audioOutput) {
                    self.captureSession.addOutput(self.audioOutput)
                }
            }
            
            self.captureSession.commitConfiguration()
            
            // Reset state trackers
            DispatchQueue.main.async {
                self.zoomFactor = 1.0
                self.exposureBias = 0.0
                self.isTorchOn = false
                self.focusMode = .continuousAutoFocus
            }
        }
    }
    
    private func setSessionPreset(width: Int, height: Int) {
        let maxDim = max(width, height)
        if maxDim >= 3840 {
            if captureSession.canSetSessionPreset(.hd4K3840x2160) {
                captureSession.sessionPreset = .hd4K3840x2160
            } else {
                captureSession.sessionPreset = .hd1920x1080
            }
        } else if maxDim >= 1920 {
            if captureSession.canSetSessionPreset(.hd1920x1080) {
                captureSession.sessionPreset = .hd1920x1080
            } else {
                captureSession.sessionPreset = .hd1280x720
            }
        } else {
            if captureSession.canSetSessionPreset(.hd1280x720) {
                captureSession.sessionPreset = .hd1280x720
            } else {
                captureSession.sessionPreset = .medium
            }
        }
    }
    
    private func findVideoDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInDualCamera, .builtInTripleCamera],
            mediaType: .video,
            position: position
        )
        return discoverySession.devices.first
    }
    
    private func configureFPS(device: AVCaptureDevice, targetWidth: Int, targetHeight: Int, fps: Int) {
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            let targetPixels = targetWidth * targetHeight

            // Pass 1: Find format matching both resolution and FPS
            var bestFormat: AVCaptureDevice.Format?
            var bestPixelDiff = Int.max

            for format in device.formats {
                // Check FPS support
                let supportsFps = format.videoSupportedFrameRateRanges.contains {
                    $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps)
                }
                guard supportsFps else { continue }

                // Check resolution match
                let desc = format.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let w = Int(dims.width)
                let h = Int(dims.height)

                // Only consider formats with same aspect ratio (16:9 for our presets)
                let isLandscape = w >= h
                let fw = isLandscape ? w : h
                let fh = isLandscape ? h : w
                let tw = max(targetWidth, targetHeight)
                let th = min(targetWidth, targetHeight)

                guard fw >= tw && fh >= th else { continue }

                let diff = (fw * fh) - targetPixels
                if diff < bestPixelDiff {
                    bestPixelDiff = diff
                    bestFormat = format
                }
            }

            // Pass 2: If no format matches both, find format matching resolution only
            if bestFormat == nil {
                bestPixelDiff = Int.max
                for format in device.formats {
                    let desc = format.formatDescription
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let w = Int(dims.width)
                    let h = Int(dims.height)

                    let isLandscape = w >= h
                    let fw = isLandscape ? w : h
                    let fh = isLandscape ? h : w
                    let tw = max(targetWidth, targetHeight)
                    let th = min(targetWidth, targetHeight)

                    guard fw >= tw && fh >= th else { continue }

                    let diff = (fw * fh) - targetPixels
                    if diff < bestPixelDiff {
                        bestPixelDiff = diff
                        bestFormat = format
                    }
                }
            }

            // Apply the chosen format (or keep the active one if none found)
            let activeFormat = bestFormat ?? device.activeFormat
            if device.activeFormat != activeFormat {
                device.activeFormat = activeFormat
            }

            // Find the closest supported frame rate in the selected format
            var targetFps = Double(fps)
            var matchedRange: AVFrameRateRange?
            
            for range in activeFormat.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps {
                    matchedRange = range
                    break
                }
            }
            
            if matchedRange == nil {
                // Clamp target FPS to the format's limits
                if let firstRange = activeFormat.videoSupportedFrameRateRanges.first {
                    targetFps = max(firstRange.minFrameRate, min(firstRange.maxFrameRate, targetFps))
                    matchedRange = firstRange
                }
            }

            if matchedRange != nil {
                print("Setting camera FPS to \(targetFps) (requested: \(fps))")
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            } else {
                print("Warning: Could not find valid frame rate range for format")
            }
        } catch {
            print("Could not lock device for FPS configuration: \(error)")
        }
    }
    
    func start() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                DispatchQueue.main.async { self.isRunning = true }
            }
        }
    }
    
    func stop() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
                DispatchQueue.main.async { self.isRunning = false }
            }
        }
    }
    
    func toggleCamera() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.activeCameraPosition = (self.activeCameraPosition == .back) ? .front : .back
            let settings = SettingsManager.shared
            self.configureSession(
                width: settings.getWidth(),
                height: settings.getHeight(),
                fps: settings.fps,
                audioEnabled: settings.audioEnabled
            )
        }
    }
    
    // MARK: - Manual Controls
    
    func setZoom(_ factor: CGFloat) {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        do {
            try device.lockForConfiguration()
            let minZoom = device.minAvailableVideoZoomFactor
            let maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0) // cap zoom at 10x
            let clampZoom = max(minZoom, min(factor, maxZoom))
            device.videoZoomFactor = clampZoom
            device.unlockForConfiguration()
            
            DispatchQueue.main.async { self.zoomFactor = clampZoom }
        } catch {
            print("Failed to set zoom: \(error)")
        }
    }
    
    func setExposureBias(_ bias: Float) {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        do {
            try device.lockForConfiguration()
            let minBias = device.minExposureTargetBias
            let maxBias = device.maxExposureTargetBias
            let clampBias = max(minBias, min(bias, maxBias))
            device.setExposureTargetBias(clampBias, completionHandler: nil)
            device.unlockForConfiguration()
            
            DispatchQueue.main.async { self.exposureBias = clampBias }
        } catch {
            print("Failed to set exposure bias: \(error)")
        }
    }
    
    func setFocusMode(_ mode: AVCaptureDevice.FocusMode) {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        guard device.isFocusModeSupported(mode) else { return }
        
        do {
            try device.lockForConfiguration()
            device.focusMode = mode
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.focusMode = mode }
        } catch {
            print("Failed to set focus mode: \(error)")
        }
    }
    
    func setLensPosition(_ position: Float) {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        do {
            try device.lockForConfiguration()
            device.setFocusModeLocked(lensPosition: position) { _ in }
            device.unlockForConfiguration()
            DispatchQueue.main.async {
                self.focusMode = .locked
                self.lensPosition = position
            }
        } catch {
            print("Failed to set lens position: \(error)")
        }
    }
    
    func toggleTorch() {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        guard device.hasTorch && device.isTorchAvailable else { return }
        
        do {
            try device.lockForConfiguration()
            if device.torchMode == .on {
                device.torchMode = .off
                DispatchQueue.main.async { self.isTorchOn = false }
            } else {
                try device.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel)
                DispatchQueue.main.async { self.isTorchOn = true }
            }
            device.unlockForConfiguration()
        } catch {
            print("Failed to toggle torch: \(error)")
        }
    }
    
    // MARK: - White Balance
    
    func setWhiteBalance(mode: AVCaptureDevice.WhiteBalanceMode) {
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        do {
            try device.lockForConfiguration()
            device.whiteBalanceMode = mode
            device.unlockForConfiguration()
            DispatchQueue.main.async { self.whiteBalanceMode = mode }
        } catch {
            print("Failed to set white balance: \(error)")
        }
    }
    
    func applyWhiteBalancePreset(_ preset: String) {
        // iOS doesn't have named WB presets like Android; use auto for all
        setWhiteBalance(mode: .continuousAutoWhiteBalance)
        DispatchQueue.main.async { self.currentWBMode = preset }
    }
    
    // MARK: - Filters (via AVCaptureVideoPreviewLayer videoMirroring is not available, use device properties)
    
    func applyFilter(_ filter: String) {
        // Note: AVCaptureDevice doesn't have built-in filter support like Android's CONTROL_EFFECT_MODE
        // We'll implement this via GPU-based filtering in the future if needed
        // For now, just track the current filter
        DispatchQueue.main.async { self.currentFilter = filter }
        
        // Apply color matrix effects using device configuration where possible
        guard let input = videoDeviceInput else { return }
        let device = input.device
        
        // Note: iOS doesn't have named white balance presets; filters are a no-op for now
    }
    
    // MARK: - Stabilization
    
    func setOIS(_ enabled: Bool) {
        guard let connection = videoOutput.connection(with: .video) else { return }
        
        if connection.isVideoStabilizationSupported {
            let mode: AVCaptureVideoStabilizationMode = enabled ? .auto : .off
            connection.preferredVideoStabilizationMode = mode
        }
        
        DispatchQueue.main.async { self.isOISEnabled = enabled }
    }
    
    func setEIS(_ enabled: Bool) {
        // On iOS, EIS is controlled via AVCaptureDevice's videoStabilizationMode
        // .auto uses the best available stabilization (OIS + EIS)
        setOIS(enabled) // Both OIS and EIS are controlled together on iOS
        DispatchQueue.main.async { self.isEISEnabled = enabled }
    }
    
    // MARK: - AVCaptureDataOutput SampleBuffer Delegates
    
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output == videoOutput {
            onVideoSampleBuffer?(sampleBuffer)
        } else if output == audioOutput {
            onAudioSampleBuffer?(sampleBuffer)
        }
    }
    
    // MARK: - Session Interruption Handling (Notification-based, iOS 15 compatible)
    
    func setupInterruptionNotifications() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionWasInterrupted(_:)),
            name: .AVCaptureSessionWasInterrupted,
            object: captureSession
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(sessionInterruptionEnded(_:)),
            name: .AVCaptureSessionInterruptionEnded,
            object: captureSession
        )
    }
    
    @objc private func sessionWasInterrupted(_ notification: Notification) {
        print("Session was interrupted")
        
        DispatchQueue.main.async {
            self.isRunning = false
        }
    }
    
    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        print("Session interruption ended")
        
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            
            if !self.captureSession.isRunning {
                self.captureSession.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                }
            }
            
            let settings = SettingsManager.shared
            self.configureSession(
                width: settings.getWidth(),
                height: settings.getHeight(),
                fps: settings.fps,
                audioEnabled: settings.audioEnabled
            )
        }
    }
}
