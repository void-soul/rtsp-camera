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
            if let conn = context.coordinator.previewLayer?.connection, conn.isVideoOrientationSupported {
                conn.videoOrientation = .landscapeRight
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        var previewLayer: AVCaptureVideoPreviewLayer?
    }
}

// MARK: - Parameter Popup Menu (inline, like Android PopupMenu)
struct ParamMenu: View {
    let title: String
    let options: [String]
    @Binding var selection: String
    var isActive: Bool = false
    var disabled: Bool = false
    var onSelect: ((String) -> Void)?

    @State private var showing = false

    var body: some View {
        Button(action: { if !disabled { showing = true } }) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.6))
                Text(displayValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(isActive ? Color(red: 1, green: 0.84, blue: 0) : .white)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(disabled ? 0.35 : 1.0)
        .popover(isPresented: $showing) {
            VStack(spacing: 0) {
                ForEach(options, id: \.self) { opt in
                    Button(action: {
                        selection = opt
                        onSelect?(opt)
                        showing = false
                    }) {
                        HStack {
                            Text(opt)
                                .font(.system(size: 13))
                                .foregroundColor(opt == selection ? .blue : .primary)
                            Spacer()
                            if opt == selection {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    if opt != options.last {
                        Divider().padding(.leading, 14)
                    }
                }
            }
            .frame(minWidth: 120)
        }
    }

    private var displayValue: String {
        if title == "BITRATE" { return selection }
        if title == "FPS" { return selection }
        if title == "GOP" { return "K:\(selection)" }
        return selection
    }
}

// MARK: - Bottom Control Button
struct ControlButton: View {
    let label: String
    let value: String
    var isActive: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white)
                Text(value)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(red: 1, green: 0.84, blue: 0))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Divider
struct VerticalDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.2))
            .frame(width: 1, height: 14)
    }
}

// MARK: - Main Content View
struct ContentView: View {
    @ObservedObject private var streamManager = StreamManager.shared
    @ObservedObject private var cameraManager = StreamManager.shared.cameraManager

    @State private var showCopiedToast = false
    @State private var showNetworkDialog = false
    @State private var showHelpDialog = false
    @State private var isUiVisible = true
    @State private var showAlertBorder = false

    // Active bottom control mode: nil, "zoom", "ev", "focus"
    @State private var activeControl: String? = nil

    // Local slider values
    @State private var localZoom: CGFloat = 1.0
    @State private var localExposure: Float = 0.0
    @State private var localLensPosition: Float = 0.5
    @State private var isManualFocus = false

    // Settings (inline, directly editable)
    @State private var resolution = SettingsManager.shared.resolution
    @State private var bitrate = "\(SettingsManager.shared.bitrate)"
    @State private var fps = "\(SettingsManager.shared.fps)"
    @State private var gop = "\(SettingsManager.shared.gop)"
    @State private var codec = SettingsManager.shared.videoCodec
    @State private var audioEnabled = SettingsManager.shared.audioEnabled
    @State private var previewEnabled = SettingsManager.shared.previewEnabled
    @State private var perfEnabled = SettingsManager.shared.perfMonitorEnabled

    private let resolutions = ["3840x2160", "1920x1080", "1280x720"]
    private let bitrates = ["5", "10", "15", "20", "25", "30", "35", "40", "50", "60"]
    private let fpsList = ["120", "60", "30", "24"]
    private let gopList = ["1", "5", "10", "15", "20", "25", "30", "40", "50", "60", "80", "100", "120"]
    private let codecs = ["h264", "h265"]

    var body: some View {
        ZStack {
            // Layer 1: Camera preview (full screen) - always visible when camera is running
            if cameraManager.isRunning && previewEnabled {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
            }

            // Layer 2: Center status (when preview off or idle)
            if !previewEnabled || !cameraManager.isRunning {
                centerStatusView
            }

            // Layer 3-6: UI overlay
            if isUiVisible {
                VStack(spacing: 0) {
                    topBar
                    Spacer()
                    if activeControl != nil && streamManager.isServerRunning {
                        rulerSlider
                    }
                    bottomBar
                }
                .ignoresSafeArea(edges: .bottom)

                // Start/Stop button (right edge)
                startStopButton
            }

            // Performance HUD
            if perfEnabled && streamManager.isServerRunning {
                perfOverlay
            }
            
            // Alert border (flashes red when client disconnects)
            if showAlertBorder || streamManager.clientDisconnected {
                alertBorderOverlay
            }
        }
        .statusBarHidden(true)
        .preferredColorScheme(.dark)
        .onTapGesture { isUiVisible.toggle() }
        .alert("Network Settings", isPresented: $showNetworkDialog) {
            // Handled separately below
        }
        .overlay {
            if showNetworkDialog {
                networkDialogOverlay
            }
        }
        .overlay {
            if showWBPopup {
                wbPopupOverlay
            }
        }
        .overlay {
            if showFilterPopup {
                filterPopupOverlay
            }
        }
        .overlay {
            if showHelpDialog {
                helpDialogOverlay
            }
        }
        .overlay {
            if showCopiedToast {
                VStack {
                    Spacer()
                    Text("URL Copied")
                        .font(.caption)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                        .padding(.bottom, 80)
                }
                .transition(.opacity)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        showCopiedToast = false
                    }
                }
            }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            // Start camera preview on app launch (always visible)
            startCameraPreview()
        }
    }

    // MARK: - Center Status (idle / preview off)

    private var centerStatusView: some View {
        VStack(spacing: 12) {
            if streamManager.isServerRunning {
                Text(streamManager.streamUrl)
                    .font(.system(size: 18, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
                    .onTapGesture {
                        UIPasteboard.general.string = streamManager.streamUrl
                        showCopiedToast = true
                    }
                if let client = streamManager.clientIp {
                    Text(client)
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(Color(red: 1, green: 0.27, blue: 0.27))
                }
                Text(streamManager.transportMode)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            } else {
                // Show placeholder URL when server is not running
                let settings = SettingsManager.shared
                let ip = Utils.getIPAddress()
                let placeholderUrl = "rtsp://\(ip):\(settings.rtspPort)\(settings.rtspPath)"
                
                Text(placeholderUrl)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .onTapGesture {
                        UIPasteboard.general.string = placeholderUrl
                        showCopiedToast = true
                    }
                
                Text("Press play to start streaming")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 0) {
            // Left: inline parameter labels
            ParamMenu(title: "RES", options: resolutions, selection: $resolution,
                      disabled: streamManager.isClientConnected) { val in
                SettingsManager.shared.resolution = val
            }
            VerticalDivider()
            ParamMenu(title: "BITRATE", options: bitrates.map { "\($0) Mbps" },
                      selection: Binding(
                        get: { "\(bitrate) Mbps" },
                        set: { bitrate = $0.replacingOccurrences(of: " Mbps", with: "") }
                      )) { val in
                SettingsManager.shared.bitrate = Int(val.replacingOccurrences(of: " Mbps", with: "")) ?? 30
            }
            VerticalDivider()
            ParamMenu(title: "FPS", options: fpsList, selection: $fps,
                      isActive: true) { val in
                SettingsManager.shared.fps = Int(val) ?? 30
            }
            VerticalDivider()
            ParamMenu(title: "GOP", options: gopList, selection: $gop) { val in
                SettingsManager.shared.gop = Int(val) ?? 60
            }
            VerticalDivider()
            ParamMenu(title: "CODEC", options: codecs.map { $0.uppercased() },
                      selection: Binding(
                        get: { codec.uppercased() },
                        set: { codec = $0.lowercased() }
                      ),
                      disabled: streamManager.isServerRunning) { val in
                SettingsManager.shared.videoCodec = val.lowercased()
            }

            Spacer(minLength: 8)

            // Center: RTSP URL
            if streamManager.isServerRunning {
                HStack(spacing: 4) {
                    Text(streamManager.streamUrl)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                        .onTapGesture {
                            UIPasteboard.general.string = streamManager.streamUrl
                            showCopiedToast = true
                        }
                    Text(streamManager.transportMode)
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                    if let client = streamManager.clientIp {
                        Text(client)
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(Color(red: 1, green: 0.27, blue: 0.27))
                    }
                }
            }

            Spacer(minLength: 8)

            // WiFi info (when streaming)
            if streamManager.isServerRunning {
                HStack(spacing: 4) {
                    Image(systemName: "wifi")
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                    Text(wifiInfo)
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.4))
                }
                Spacer(minLength: 4)
            }

            // Right: icon buttons
            HStack(spacing: 4) {
                // Preview toggle
                topBarButton(
                    icon: previewEnabled ? "eye.fill" : "eye.slash.fill",
                    isActive: previewEnabled
                ) {
                    previewEnabled.toggle()
                    SettingsManager.shared.previewEnabled = previewEnabled
                }

                // Audio toggle
                topBarButton(
                    icon: audioEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                    isActive: audioEnabled,
                    disabled: streamManager.isServerRunning
                ) {
                    audioEnabled.toggle()
                    SettingsManager.shared.audioEnabled = audioEnabled
                }

                // Flash
                topBarButton(
                    icon: cameraManager.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    isActive: cameraManager.isTorchOn
                ) {
                    cameraManager.toggleTorch()
                }

                // Flip camera
                topBarButton(icon: "camera.rotate.fill", disabled: streamManager.isServerRunning) {
                    cameraManager.toggleCamera()
                }

                // Network settings
                topBarButton(icon: "network", disabled: streamManager.isServerRunning) {
                    showNetworkDialog = true
                }

                // Perf toggle
                topBarButton(icon: "chart.bar.fill", isActive: perfEnabled) {
                    perfEnabled.toggle()
                    SettingsManager.shared.perfMonitorEnabled = perfEnabled
                }
                
                // Help button
                topBarButton(icon: "questionmark.circle") {
                    showHelpDialog = true
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.27))
    }

    private func topBarButton(icon: String, isActive: Bool = false, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(isActive ? Color(red: 1, green: 0.84, blue: 0) : .white)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1.0)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ControlButton(label: "ZOOM", value: String(format: "%.1fx", localZoom),
                          isActive: activeControl == "zoom") {
                toggleControl("zoom")
            }
            ControlButton(label: "EV", value: String(format: "%+.0f", localExposure),
                          isActive: activeControl == "ev") {
                toggleControl("ev")
            }
            ControlButton(label: "FOCUS", value: isManualFocus ? "MF" : "AF",
                          isActive: activeControl == "focus") {
                toggleControl("focus")
            }
            ControlButton(label: "WB", value: cameraManager.currentWBMode,
                          isActive: activeControl == "wb") {
                showWBPopup = true
            }
            ControlButton(label: "FILTER", value: cameraManager.currentFilter,
                          isActive: activeControl == "filter") {
                showFilterPopup = true
            }
        }
        .frame(height: 44)
        .background(Color.black.opacity(0.67))
    }
    
    // MARK: - White Balance Popup
    
    @State private var showWBPopup = false
    @State private var showFilterPopup = false
    
    private var wbPopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showWBPopup = false }
            
            VStack(spacing: 0) {
                Text("White Balance")
                    .font(.headline)
                    .padding()
                
                ForEach(["AUTO", "INCANDESCENT", "FLUORESCENT", "DAYLIGHT", "CLOUDY"], id: \.self) { mode in
                    Button(action: {
                        cameraManager.applyWhiteBalancePreset(mode)
                        showWBPopup = false
                    }) {
                        HStack {
                            Text(mode)
                                .foregroundColor(mode == cameraManager.currentWBMode ? .blue : .primary)
                            Spacer()
                            if mode == cameraManager.currentWBMode {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .frame(width: 200)
        }
    }
    
    // MARK: - Filter Popup
    
    private var filterPopupOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showFilterPopup = false }
            
            VStack(spacing: 0) {
                Text("Filter")
                    .font(.headline)
                    .padding()
                
                ForEach(["None", "B&W", "VIVID", "WARM", "COOL"], id: \.self) { filter in
                    Button(action: {
                        cameraManager.applyFilter(filter)
                        showFilterPopup = false
                    }) {
                        HStack {
                            Text(filter)
                                .foregroundColor(filter == cameraManager.currentFilter ? .blue : .primary)
                            Spacer()
                            if filter == cameraManager.currentFilter {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .frame(width: 200)
        }
    }
    
    // MARK: - Alert Border (Client Disconnect)
    
    private var alertBorderOverlay: some View {
        ZStack {
            // Animated red border that flashes
            RoundedRectangle(cornerRadius: 0)
                .stroke(Color.red, lineWidth: 4)
                .ignoresSafeArea()
                .opacity(alertBorderOpacity)
                .animation(
                    Animation.easeInOut(duration: 0.8)
                        .repeatForever(autoreverses: true),
                    value: alertBorderOpacity
                )
        }
        .onAppear {
            alertBorderOpacity = 1.0
        }
        .onDisappear {
            alertBorderOpacity = 0.0
        }
    }
    
    @State private var alertBorderOpacity: Double = 0.0
    
    // MARK: - Help Dialog
    
    private var helpDialogOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showHelpDialog = false }
            
            VStack(spacing: 0) {
                Text("Help")
                    .font(.headline)
                    .padding()
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        helpItem("Camera Preview", "Always visible. Toggle with eye icon in top bar.")
                        helpItem("Start/Stop", "Red button on right edge starts/stops RTSP streaming.")
                        helpItem("Resolution", "Tap RES to change (4K/1080p/720p).")
                        helpItem("Bitrate", "Tap BITRATE to adjust (5-60 Mbps).")
                        helpItem("FPS", "Tap FPS to set frame rate (24/30/60/120).")
                        helpItem("GOP", "Tap GOP to set keyframe interval (I-frame every N frames).")
                        helpItem("Codec", "Tap CODEC to switch H.264/H.265 (only when not streaming).")
                        helpItem("Zoom", "Tap ZOOM, then use slider (1x-10x).")
                        helpItem("Exposure", "Tap EV, then use slider (-3 to +3).")
                        helpItem("Focus", "Tap FOCUS, then AF/MF toggle + slider.")
                        helpItem("White Balance", "Tap WB for presets (Auto/Incandescent/Daylight/Cloudy).")
                        helpItem("Filter", "Tap FILTER for effects (B&W/Vivid/Warm/Cool).")
                        helpItem("Audio", "Toggle microphone with speaker icon.")
                        helpItem("Flash", "Toggle torch with flashlight icon.")
                        helpItem("Camera Flip", "Switch front/back with rotate icon.")
                        helpItem("Preview Off", "Hide preview to save battery (eye icon).")
                        helpItem("Performance", "Toggle HUD with chart icon.")
                        helpItem("Network Settings", "Change RTSP port and path with network icon.")
                    }
                    .padding(.horizontal, 16)
                }
                
                Divider()
                
                Button("Close") { showHelpDialog = false }
                    .padding()
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .frame(width: 320, height: 400)
        }
    }
    
    private func helpItem(_ title: String, _ description: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.primary)
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Ruler Slider (replaces RulerWheelView)

    private var rulerSlider: some View {
        HStack(spacing: 8) {
            if activeControl == "zoom" {
                Text("1x")
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
                Slider(value: $localZoom, in: 1...min(10, cameraManager.zoomFactor > 1 ? 10 : 10))
                    .onChange(of: localZoom) { cameraManager.setZoom($0) }
                Text(String(format: "%.0fx", localZoom))
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
                    .frame(width: 28)
            } else if activeControl == "ev" {
                Text("-3")
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
                Slider(value: $localExposure, in: -3...3)
                    .onChange(of: localExposure) { cameraManager.setExposureBias($0) }
                Text("+3")
                    .font(.caption2).foregroundColor(.white.opacity(0.6))
                    .frame(width: 28)
            } else if activeControl == "focus" {
                HStack(spacing: 8) {
                    Button(action: {
                        isManualFocus.toggle()
                        if !isManualFocus {
                            cameraManager.setFocusMode(.continuousAutoFocus)
                        } else {
                            cameraManager.setLensPosition(localLensPosition)
                        }
                    }) {
                        Text(isManualFocus ? "MF" : "AF")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(isManualFocus ? Color.orange : Color.blue)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    if isManualFocus {
                        Text("0")
                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                        Slider(value: $localLensPosition, in: 0...1)
                            .onChange(of: localLensPosition) { cameraManager.setLensPosition($0) }
                        Text("1")
                            .font(.caption2).foregroundColor(.white.opacity(0.6))
                            .frame(width: 28)
                    } else {
                        Text("Continuous Auto Focus")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.5))
                        Spacer()
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.67))
    }

    // MARK: - Start/Stop Button (right edge, like Android fabAction)

    private var startStopButton: some View {
        HStack {
            Spacer()
            Button(action: {
                if streamManager.isServerRunning {
                    streamManager.stopServer()
                } else {
                    applySettingsAndStart()
                }
            }) {
                ZStack {
                    // White ring
                    Circle()
                        .strokeBorder(Color.white, lineWidth: 3)
                        .frame(width: 64, height: 64)
                    // Red fill
                    Circle()
                        .fill(Color(red: 1, green: 0.27, blue: 0.23))
                        .frame(width: 48, height: 48)
                    // Icon
                    Image(systemName: streamManager.isServerRunning ? "xmark" : "play.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                }
            }
            .buttonStyle(.plain)
            .padding(.trailing, 16)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: - Performance HUD

    private var perfOverlay: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(format: "FPS: %.1f", streamManager.currentFps))
                .foregroundColor(Color(red: 0, green: 1, blue: 0))
            Text(streamManager.perfStatus)
                .foregroundColor(.white.opacity(0.7))
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(6)
        .background(Color.black.opacity(0.65))
        .cornerRadius(4)
        .padding(.top, 40)
        .padding(.leading, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Network Dialog

    @State private var editPort = ""
    @State private var editPath = ""

    private var networkDialogOverlay: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { showNetworkDialog = false }

            VStack(spacing: 16) {
                Text("Network Settings")
                    .font(.headline)

                HStack {
                    Text("RTSP Port")
                        .frame(width: 80, alignment: .leading)
                    TextField("Port", text: $editPort)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }

                HStack {
                    Text("RTSP Path")
                        .frame(width: 80, alignment: .leading)
                    TextField("Path", text: $editPath)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 20) {
                    Button("Cancel") { showNetworkDialog = false }
                        .keyboardShortcut(.cancelAction)
                    Button("OK") {
                        if let p = Int(editPort), p > 0, p < 65536, editPath.hasPrefix("/") {
                            SettingsManager.shared.rtspPort = p
                            SettingsManager.shared.rtspPath = editPath
                        }
                        showNetworkDialog = false
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .frame(width: 320)
        }
        .onAppear {
            editPort = "\(SettingsManager.shared.rtspPort)"
            editPath = SettingsManager.shared.rtspPath
        }
    }

    // MARK: - Helpers
    
    private var wifiInfo: String {
        // Get WiFi SSID and signal strength
        // Note: This is a simplified version - real implementation would use CoreLocation and NetworkExtension
        return "WiFi"
    }

    private func toggleControl(_ name: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if activeControl == name {
                activeControl = nil
            } else {
                activeControl = name
            }
        }
    }

    private func startCameraPreview() {
        let settings = SettingsManager.shared
        // Configure camera with lower resolution for preview to save power
        let previewWidth = 1280
        let previewHeight = 720
        
        streamManager.cameraManager.configureSession(
            width: previewWidth,
            height: previewHeight,
            fps: settings.fps,
            audioEnabled: false // No audio needed for preview only
        )
        streamManager.cameraManager.start()
    }

    private func applySettingsAndStart() {
        let s = SettingsManager.shared
        s.resolution = resolution
        s.fps = Int(fps) ?? 30
        s.bitrate = Int(bitrate) ?? 30
        s.gop = Int(gop) ?? 60
        s.videoCodec = codec
        s.audioEnabled = audioEnabled
        streamManager.startServer()
    }

}
