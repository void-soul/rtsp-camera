import SwiftUI
import AVFoundation

// MARK: - Camera Preview Wrapper
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .black
        
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)
        
        context.coordinator.previewLayer = previewLayer
        return view
    }
    
    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            context.coordinator.previewLayer?.frame = uiView.bounds
            
            // Adjust orientation if connection is available
            if let connection = context.coordinator.previewLayer?.connection {
                if connection.isVideoOrientationSupported {
                    // Match default portrait layout of the UI
                    connection.videoOrientation = .portrait
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Main UI View
struct ContentView: View {
    @ObservedObject private var streamManager = StreamManager.shared
    @ObservedObject private var cameraManager = StreamManager.shared.cameraManager

    @State private var isShowingSettings = false
    @State private var showingCopiedAlert = false
    @State private var isManualFocus = false
    
    // Sliders bound locally to avoid rapid lockForConfiguration updates
    @State private var localZoom: CGFloat = 1.0
    @State private var localExposure: Float = 0.0
    @State private var localLensPosition: Float = 0.5
    
    var body: some View {
        ZStack {
            // Camera Preview Background
            if streamManager.isServerRunning {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 20) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 80))
                        .foregroundColor(.gray.opacity(0.6))
                    Text("RTSP Camera Streamer")
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Connect via USB or Wi-Fi to start streaming")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
            }
            
            // UI Overlay Controls
            VStack {
                // Top controls bar (Glassmorphic)
                HStack {
                    Button(action: {
                        cameraManager.toggleTorch()
                    }) {
                        Image(systemName: cameraManager.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2)
                            .foregroundColor(cameraManager.isTorchOn ? .yellow : .white)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    
                    Spacer()
                    
                    Text(streamManager.isServerRunning ? "SERVER ACTIVE" : "SERVER IDLE")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(streamManager.isServerRunning ? Color.green.opacity(0.8) : Color.gray.opacity(0.8))
                        .foregroundColor(.white)
                        .cornerRadius(20)
                    
                    Spacer()
                    
                    Button(action: {
                        isShowingSettings = true
                    }) {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .frame(width: 48, height: 48)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .disabled(streamManager.isClientConnected) // Lock settings during active client stream
                }
                .padding(.horizontal)
                .padding(.top, 10)
                
                Spacer()
                
                // Camera manual adjustment sliders (Left & Right side controls)
                if streamManager.isServerRunning {
                    HStack {
                        // Focus & Exposure controls (Left)
                        VStack(spacing: 20) {
                            // Focus Auto/Manual toggle and slider
                            VStack(spacing: 5) {
                                Button(action: {
                                    isManualFocus.toggle()
                                    if !isManualFocus {
                                        cameraManager.setFocusMode(.continuousAutoFocus)
                                    } else {
                                        cameraManager.setLensPosition(localLensPosition)
                                    }
                                }) {
                                    Text(isManualFocus ? "MF" : "AF")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                        .background(isManualFocus ? Color.orange : Color.blue)
                                        .clipShape(Circle())
                                }
                                
                                if isManualFocus {
                                    Slider(value: $localLensPosition, in: 0...1)
                                        .onChange(of: localLensPosition) { val in
                                            cameraManager.setLensPosition(val)
                                        }
                                        .frame(height: 100)
                                        .rotationEffect(.degrees(-90))
                                }
                            }
                            
                            // Exposure bias slider
                            VStack(spacing: 5) {
                                Image(systemName: "sun.max.fill")
                                    .foregroundColor(.white)
                                    .font(.caption)
                                Slider(value: $localExposure, in: -3...3)
                                    .onChange(of: localExposure) { val in
                                        cameraManager.setExposureBias(val)
                                    }
                                    .frame(height: 100)
                                    .rotationEffect(.degrees(-90))
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(15)
                        .padding(.leading, 10)
                        
                        Spacer()
                        
                        // Zoom Slider (Right)
                        VStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.white)
                            
                            Slider(value: $localZoom, in: 1...8)
                                .onChange(of: localZoom) { val in
                                    cameraManager.setZoom(val)
                                }
                                .frame(height: 150)
                                .rotationEffect(.degrees(-90))
                            
                            // Quick zoom toggles
                            Button("1x") {
                                localZoom = 1.0
                                cameraManager.setZoom(1.0)
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.vertical, 4)
                            
                            Button("2x") {
                                localZoom = 2.0
                                cameraManager.setZoom(2.0)
                            }
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding(.vertical, 4)
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(15)
                        .padding(.trailing, 10)
                    }
                }
                
                Spacer()
                
                // Bottom control panel & Stream info
                VStack(spacing: 15) {
                    if streamManager.isServerRunning {
                        // RTSP URL information
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Image(systemName: "link")
                                    .foregroundColor(.blue)
                                Text(streamManager.streamUrl)
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                
                                Spacer()
                                
                                Button(action: {
                                    UIPasteboard.general.string = streamManager.streamUrl
                                    showingCopiedAlert = true
                                }) {
                                    Image(systemName: "doc.on.doc.fill")
                                        .foregroundColor(.white)
                                }
                            }
                            
                            if streamManager.isClientConnected, let client = streamManager.clientIp {
                                Divider().background(Color.white.opacity(0.3))
                                HStack {
                                    Image(systemName: "personalhotspot")
                                        .foregroundColor(.green)
                                    Text("Client Connected: \(client)")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                    Spacer()
                                    Text("Mode: \(streamManager.transportMode)")
                                        .font(.caption)
                                        .foregroundColor(.gray)
                                }
                            }
                        }
                        .padding()
                        .background(.ultraThinMaterial)
                        .cornerRadius(12)
                        .padding(.horizontal)
                        .alert(isPresented: $showingCopiedAlert) {
                            Alert(title: Text("URL Copied"), message: Text("The RTSP stream address has been copied to your clipboard."), dismissButton: .default(Text("OK")))
                        }
                    }
                    
                    // Main Start/Stop button
                    HStack(spacing: 30) {
                        if streamManager.isServerRunning {
                            Button(action: {
                                cameraManager.toggleCamera()
                            }) {
                                Image(systemName: "camera.rotate.fill")
                                    .font(.title2)
                                    .foregroundColor(.white)
                                    .frame(width: 56, height: 56)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Circle())
                            }
                        }
                        
                        Button(action: {
                            if streamManager.isServerRunning {
                                streamManager.stopServer()
                            } else {
                                streamManager.startServer()
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(streamManager.isServerRunning ? Color.red : Color.green)
                                    .frame(width: 80, height: 80)
                                    .shadow(color: streamManager.isServerRunning ? .red.opacity(0.5) : .green.opacity(0.5), radius: 10)
                                
                                Image(systemName: streamManager.isServerRunning ? "stop.fill" : "play.fill")
                                    .font(.title)
                                    .foregroundColor(.white)
                            }
                        }
                        
                        if streamManager.isServerRunning {
                            // Dummy spacing helper to keep layout centered
                            Spacer().frame(width: 56, height: 56)
                        }
                    }
                    .padding(.bottom, 20)
                }
            }

            // Performance overlay (top-left, below top bar)
            if SettingsManager.shared.perfMonitorEnabled && streamManager.isServerRunning {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "FPS: %.1f", streamManager.currentFps))
                        .font(.system(size: 11, design: .monospaced))
                    Text(streamManager.perfStatus)
                        .font(.system(size: 11, design: .monospaced))
                }
                .foregroundColor(.green)
                .padding(6)
                .background(Color.black.opacity(0.6))
                .cornerRadius(6)
                .padding(.top, 70)
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }
}

// MARK: - Settings View Sheet
struct SettingsView: View {
    @Environment(\.dismiss) var dismiss
    
    @State private var resolution = SettingsManager.shared.resolution
    @State private var fps = SettingsManager.shared.fps
    @State private var bitrate = Double(SettingsManager.shared.bitrate)
    @State private var gop = Double(SettingsManager.shared.gop)
    @State private var rtspPort = String(SettingsManager.shared.rtspPort)
    @State private var rtspPath = SettingsManager.shared.rtspPath
    @State private var videoCodec = SettingsManager.shared.videoCodec
    @State private var audioEnabled = SettingsManager.shared.audioEnabled
    @State private var previewEnabled = SettingsManager.shared.previewEnabled
    @State private var perfMonitorEnabled = SettingsManager.shared.perfMonitorEnabled
    
    let resolutions = ["1280x720", "1920x1080", "3840x2160"]
    let codecs = ["h264", "h265"]
    let fpsList = [30, 60]
    
    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Video Settings")) {
                    Picker("Resolution", selection: $resolution) {
                        ForEach(resolutions, id: \.self) { res in
                            Text(res).tag(res)
                        }
                    }
                    
                    Picker("FPS", selection: $fps) {
                        ForEach(fpsList, id: \.self) { rate in
                            Text("\(rate)").tag(rate)
                        }
                    }
                    
                    Picker("Codec", selection: $videoCodec) {
                        ForEach(codecs, id: \.self) { c in
                            Text(c.uppercased()).tag(c)
                        }
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Bitrate")
                            Spacer()
                            Text("\(Int(bitrate)) Mbps")
                                .foregroundColor(.gray)
                        }
                        Slider(value: $bitrate, in: 1...60, step: 1)
                    }
                    
                    VStack(alignment: .leading) {
                        HStack {
                            Text("GOP (I-Frame Interval)")
                            Spacer()
                            Text("\(Int(gop)) frames")
                                .foregroundColor(.gray)
                        }
                        Slider(value: $gop, in: 10...120, step: 5)
                    }
                }
                
                Section(header: Text("RTSP Server Config")) {
                    HStack {
                        Text("Port")
                        Spacer()
                        TextField("Port", text: $rtspPort)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    
                    HStack {
                        Text("Path")
                        Spacer()
                        TextField("Path", text: $rtspPath)
                            .multilineTextAlignment(.trailing)
                    }
                }
                
                Section(header: Text("Audio & Features")) {
                    Toggle("Enable Audio (AAC)", isOn: $audioEnabled)
                    Toggle("Enable Camera Preview", isOn: $previewEnabled)
                    Toggle("Enable Performance Overlay", isOn: $perfMonitorEnabled)
                }
            }
            .navigationTitle("Configuration")
            .navigationBarItems(
                leading: Button("Cancel") {
                    dismiss()
                },
                trailing: Button("Save") {
                    saveSettings()
                    dismiss()
                }
            )
        }
    }
    
    private func saveSettings() {
        let settings = SettingsManager.shared
        settings.resolution = resolution
        settings.fps = fps
        settings.videoCodec = videoCodec
        settings.bitrate = Int(bitrate)
        settings.gop = Int(gop)
        settings.rtspPort = Int(rtspPort) ?? 9527
        settings.rtspPath = rtspPath
        settings.audioEnabled = audioEnabled
        settings.previewEnabled = previewEnabled
        settings.perfMonitorEnabled = perfMonitorEnabled
    }
}
