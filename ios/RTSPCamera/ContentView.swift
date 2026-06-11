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

            if let connection = context.coordinator.previewLayer?.connection {
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
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

// MARK: - Main UI View (Landscape Layout)
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
            // Camera Preview Background (fills entire screen)
            if streamManager.isServerRunning {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()

                // Idle landing screen
                VStack(spacing: 16) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 60))
                        .foregroundColor(.gray.opacity(0.6))
                    Text("RTSP Camera Streamer")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Tap Start to begin streaming")
                        .font(.subheadline)
                        .foregroundColor(.gray)

                    Button(action: {
                        streamManager.startServer()
                    }) {
                        ZStack {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 70, height: 70)
                                .shadow(color: .green.opacity(0.5), radius: 10)
                            Image(systemName: "play.fill")
                                .font(.title)
                                .foregroundColor(.white)
                        }
                    }
                    .padding(.top, 8)
                }
            }

            // UI Overlay (only when server is running)
            if streamManager.isServerRunning {
                VStack(spacing: 0) {
                    // Top bar
                    topBar

                    Spacer()

                    // Bottom control panel
                    bottomPanel
                }
                .ignoresSafeArea(.container, edges: .bottom)

                // Performance overlay (top-left, below top bar)
                if SettingsManager.shared.perfMonitorEnabled {
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
                    .padding(.top, 50)
                    .padding(.leading, 10)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            // Torch
            Button(action: { cameraManager.toggleTorch() }) {
                Image(systemName: cameraManager.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                    .font(.body)
                    .foregroundColor(cameraManager.isTorchOn ? .yellow : .white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            Spacer()

            // Server status
            Text("ACTIVE")
                .font(.caption2)
                .fontWeight(.bold)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.green.opacity(0.8))
                .foregroundColor(.white)
                .cornerRadius(12)

            Spacer()

            // Settings gear
            Button(action: { isShowingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .font(.body)
                    .foregroundColor(.white)
                    .frame(width: 36, height: 36)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }
            .disabled(streamManager.isClientConnected)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    // MARK: - Bottom Panel

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            // Camera controls row
            cameraControlsRow

            // Stream info + action buttons row
            streamInfoRow
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .bottom)
        )
    }

    // MARK: - Camera Controls Row (Horizontal)

    private var cameraControlsRow: some View {
        HStack(spacing: 12) {
            // Focus control
            HStack(spacing: 6) {
                Button(action: {
                    isManualFocus.toggle()
                    if !isManualFocus {
                        cameraManager.setFocusMode(.continuousAutoFocus)
                    } else {
                        cameraManager.setLensPosition(localLensPosition)
                    }
                }) {
                    Text(isManualFocus ? "MF" : "AF")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(isManualFocus ? Color.orange : Color.blue)
                        .clipShape(Circle())
                }

                if isManualFocus {
                    Slider(value: $localLensPosition, in: 0...1)
                        .onChange(of: localLensPosition) { val in
                            cameraManager.setLensPosition(val)
                        }
                        .frame(width: 80)
                }
            }

            Divider().frame(height: 20).background(Color.white.opacity(0.3))

            // Exposure control
            HStack(spacing: 4) {
                Image(systemName: "sun.max.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
                Slider(value: $localExposure, in: -3...3)
                    .onChange(of: localExposure) { val in
                        cameraManager.setExposureBias(val)
                    }
                    .frame(width: 80)
            }

            Divider().frame(height: 20).background(Color.white.opacity(0.3))

            // Zoom control
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.caption2)
                    .foregroundColor(.white)
                Slider(value: $localZoom, in: 1...8)
                    .onChange(of: localZoom) { val in
                        cameraManager.setZoom(val)
                    }
                    .frame(width: 80)

                Button("1x") {
                    localZoom = 1.0
                    cameraManager.setZoom(1.0)
                }
                .font(.caption2)
                .foregroundColor(.white)

                Button("2x") {
                    localZoom = 2.0
                    cameraManager.setZoom(2.0)
                }
                .font(.caption2)
                .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Stream Info Row

    private var streamInfoRow: some View {
        HStack(spacing: 10) {
            // RTSP URL
            HStack(spacing: 4) {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Text(streamManager.streamUrl)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Button(action: {
                    UIPasteboard.general.string = streamManager.streamUrl
                    showingCopiedAlert = true
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(.white)
                }
            }

            // Client info
            if streamManager.isClientConnected, let client = streamManager.clientIp {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(client)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white)
                    Text(streamManager.transportMode)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.gray)
                }
            }

            Spacer()

            // Camera flip button
            Button(action: { cameraManager.toggleCamera() }) {
                Image(systemName: "camera.rotate.fill")
                    .font(.body)
                    .foregroundColor(.white)
                    .frame(width: 32, height: 32)
                    .background(.ultraThinMaterial)
                    .clipShape(Circle())
            }

            // Stop button
            Button(action: { streamManager.stopServer() }) {
                ZStack {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 40, height: 40)
                        .shadow(color: .red.opacity(0.5), radius: 6)
                    Image(systemName: "stop.fill")
                        .font(.caption)
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .alert(isPresented: $showingCopiedAlert) {
            Alert(title: Text("URL Copied"), message: Text("RTSP address copied to clipboard."), dismissButton: .default(Text("OK")))
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
                leading: Button("Cancel") { dismiss() },
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
