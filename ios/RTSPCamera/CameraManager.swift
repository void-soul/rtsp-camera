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
            
            print("[Camera] Configuring session with resolution: \(width)x\(height), FPS: \(fps), Audio: \(audioEnabled)")
            
            let wasRunning = self.captureSession.isRunning
            if wasRunning {
                self.captureSession.stopRunning()
            }
            
            self.captureSession.beginConfiguration()
            
            // Turn off automatic audio configuration so we can configure it ourselves
            self.captureSession.automaticallyConfiguresApplicationAudioSession = false
            
            // Set session preset (resolution)
            self.setSessionPreset(width: width, height: height)
            
            // Find appropriate video device
            guard let videoDevice = self.findVideoDevice(for: self.activeCameraPosition) else {
                print("[Camera] Could not find video device for position \(self.activeCameraPosition)")
                self.captureSession.commitConfiguration()
                if wasRunning {
                    self.captureSession.startRunning()
                }
                return
            }
            
            // Configure video input (reuse if possible)
            var shouldAddVideoInput = true
            if let currentInput = self.videoDeviceInput {
                if currentInput.device == videoDevice {
                    shouldAddVideoInput = false
                    print("[Camera] Reusing existing video input")
                } else {
                    self.captureSession.removeInput(currentInput)
                    self.videoDeviceInput = nil
                }
            }
            
            if shouldAddVideoInput {
                do {
                    let videoInput = try AVCaptureDeviceInput(device: videoDevice)
                    if self.captureSession.canAddInput(videoInput) {
                        self.captureSession.addInput(videoInput)
                        self.videoDeviceInput = videoInput
                        print("[Camera] Added video input successfully")
                    } else {
                        print("[Camera] Failed to add video input")
                    }
                } catch {
                    print("[Camera] Could not create video input: \(error)")
                }
            }
            
            // Configure FPS
            self.configureFPS(device: videoDevice, targetWidth: width, targetHeight: height, fps: fps)
            
            // Configure audio input (reuse or add if enabled)
            if audioEnabled {
                var shouldAddAudioInput = true
                if let currentAudioInput = self.audioDeviceInput {
                    shouldAddAudioInput = false
                    print("[Camera] Reusing existing audio input")
                }
                
                if shouldAddAudioInput {
                    if let audioDevice = AVCaptureDevice.default(for: .audio) {
                        do {
                            let audioInput = try AVCaptureDeviceInput(device: audioDevice)
                            if self.captureSession.canAddInput(audioInput) {
                                self.captureSession.addInput(audioInput)
                                self.audioDeviceInput = audioInput
                                print("[Camera] Added audio input successfully")
                            } else {
                                print("[Camera] Failed to add audio input")
                            }
                        } catch {
                            print("[Camera] Could not create audio input: \(error)")
                        }
                    }
                }
            } else {
                // Remove audio input if disabled
                if let currentAudioInput = self.audioDeviceInput {
                    self.captureSession.removeInput(currentAudioInput)
                    self.audioDeviceInput = nil
                    print("[Camera] Removed audio input as audio is disabled")
                }
            }
            
            // Configure video output (reuse if already added)
            if !self.captureSession.outputs.contains(self.videoOutput) {
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) // NV12
                ]
                if self.captureSession.canAddOutput(self.videoOutput) {
                    self.captureSession.addOutput(self.videoOutput)
                    print("[Camera] Added video output successfully")
                } else {
                    print("[Camera] Failed to add video output")
                }
            } else {
                print("[Camera] Reusing existing video output")
            }
            // Always set the delegate and queue to ensure they are active
            self.videoOutput.setSampleBufferDelegate(self, queue: self.videoDataQueue)
            
            // Configure audio output
            if audioEnabled {
                if !self.captureSession.outputs.contains(self.audioOutput) {
                    if self.captureSession.canAddOutput(self.audioOutput) {
                        self.captureSession.addOutput(self.audioOutput)
                        print("[Camera] Added audio output successfully")
                    } else {
                        print("[Camera] Failed to add audio output")
                    }
                } else {
                    print("[Camera] Reusing existing audio output")
                }
                // Always set the delegate and queue to ensure they are active
                self.audioOutput.setSampleBufferDelegate(self, queue: self.audioDataQueue)
            } else {
                if self.captureSession.outputs.contains(self.audioOutput) {
                    self.captureSession.removeOutput(self.audioOutput)
                    print("[Camera] Removed audio output as audio is disabled")
                }
                self.audioOutput.setSampleBufferDelegate(nil, queue: nil)
            }
            
            self.captureSession.commitConfiguration()
            
            // Configure connection properties AFTER committing configuration
            if let connection = self.videoOutput.connection(with: .video) {
                connection.isEnabled = true
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                    print("[Camera] Connection videoOrientation set to landscapeRight")
                }
                if connection.isVideoStabilizationSupported {
                    connection.preferredVideoStabilizationMode = .auto
                    print("[Camera] Connection preferredVideoStabilizationMode set to auto")
                }
            } else {
                print("[Camera] Warning: video connection not found after commitConfiguration")
            }
            
            if wasRunning {
                self.captureSession.startRunning()
            }
            
            // Reset state trackers on main thread
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

            let targetFps = Double(fps)
            let currentFormat = device.activeFormat
            
            // Check if current format supports target FPS
            let currentSupportsFps = currentFormat.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= targetFps && $0.maxFrameRate >= targetFps
            }
            
            if currentSupportsFps {
                // We can just keep the current format!
                print("[Camera] Current active format supports target FPS \(fps). Keeping it.")
            } else {
                // Find a format that supports the target FPS and matches the aspect ratio/resolution
                print("[Camera] Current format does not support FPS \(fps). Searching for compatible format...")
                var bestFormat: AVCaptureDevice.Format?
                var bestPixelDiff = Int.max
                let targetPixels = targetWidth * targetHeight
                
                for format in device.formats {
                    let supportsFps = format.videoSupportedFrameRateRanges.contains {
                        $0.minFrameRate <= targetFps && $0.maxFrameRate >= targetFps
                    }
                    guard supportsFps else { continue }
                    
                    let desc = format.formatDescription
                    let dims = CMVideoFormatDescriptionGetDimensions(desc)
                    let w = Int(dims.width)
                    let h = Int(dims.height)
                    
                    // Aspect ratio check (16:9)
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
                
                if let newFormat = bestFormat {
                    print("[Camera] Found better format: \(newFormat.formatDescription)")
                    device.activeFormat = newFormat
                } else {
                    print("[Camera] Warning: Could not find format supporting FPS \(fps). Keeping current format.")
                }
            }
            
            // Set the frame rate on the active format
            let activeFormat = device.activeFormat
            var matchedRange: AVFrameRateRange?
            for range in activeFormat.videoSupportedFrameRateRanges {
                if range.minFrameRate <= targetFps && range.maxFrameRate >= targetFps {
                    matchedRange = range
                    break
                }
            }
            
            if let range = matchedRange {
                print("[Camera] Setting camera FPS to \(targetFps) (duration: 1/\(targetFps))")
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(targetFps))
            } else {
                // Clamp target FPS to format limits
                if let firstRange = activeFormat.videoSupportedFrameRateRanges.first {
                    let clampedFps = max(firstRange.minFrameRate, min(firstRange.maxFrameRate, targetFps))
                    print("[Camera] Target FPS \(fps) not supported by active format. Clamping to \(clampedFps)")
                    device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedFps))
                    device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedFps))
                }
            }
        } catch {
            print("[Camera] Error locking device for FPS configuration: \(error)")
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
