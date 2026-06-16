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

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button(action: {
                    selection = opt
                    onSelect?(opt)
                }) {
                    HStack {
                        Text(opt)
                        if opt == selection {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
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
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1.0)
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

// MARK: - LabelValueView
struct LabelValueView: View {
    let label: String
    let value: String
    var color: Color = .white
    
    var body: some View {
        HStack(spacing: 4) {
            Text("\(label):")
                .foregroundColor(.white.opacity(0.5))
            Text(value)
                .foregroundColor(color)
                .fontWeight(.semibold)
        }
        .font(.system(size: 10, design: .monospaced))
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
    /// Monotonic id bumped whenever the UI language changes; applied via `.id()` on the
    /// root so the whole view tree is rebuilt and all `L.tr()` lookups re-resolve.
    @State private var uiLangId = 0

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
        .id(uiLangId)
        .onTapGesture { isUiVisible.toggle() }
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
                    Text(L.tr("url_copied"))
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
            // Sync the in-memory language table with the persisted preference on launch.
            L.language = SettingsManager.shared.resolvedLanguage

            // Explicitly request video and audio permissions on startup
            AVCaptureDevice.requestAccess(for: .video) { videoGranted in
                if videoGranted {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async {
                            startCameraPreview()
                        }
                    }
                } else {
                    print("Camera permission denied")
                }
            }
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
                
                Text(L.tr("press_to_start"))
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
                // Reconfigure the capture session immediately so the new resolution
                // takes effect for the preview (and for the next streaming session),
                // instead of only being applied on the next startServer().
                let s = SettingsManager.shared
                streamManager.cameraManager.configureSession(
                    width: s.getWidth(),
                    height: s.getHeight(),
                    fps: s.fps,
                    audioEnabled: streamManager.isServerRunning ? s.audioEnabled : false
                )
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

                // Language switch (Auto / 中文 / EN) — flips the table language and
                // bumps uiLangId so the whole view tree re-renders with new strings.
                Menu {
                    Button("Auto") { setLanguage("auto") }
                    Button("中文")  { setLanguage("zh") }
                    Button("EN")   { setLanguage("en") }
                } label: {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundColor(.white)
                        .frame(width: 30, height: 30)
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
                Text(L.tr("white_balance"))
                    .font(.headline)
                    .padding()

                ForEach(["AUTO", "INCANDESCENT", "FLUORESCENT", "DAYLIGHT", "CLOUDY"], id: \.self) { mode in
                    Button(action: {
                        cameraManager.applyWhiteBalancePreset(mode)
                        showWBPopup = false
                    }) {
                        HStack {
                            Text(wbDisplayLabel(mode))
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
                Text(L.tr("filter"))
                    .font(.headline)
                    .padding()

                ForEach(["None", "B&W", "VIVID", "WARM", "COOL"], id: \.self) { filter in
                    Button(action: {
                        cameraManager.applyFilter(filter)
                        showFilterPopup = false
                    }) {
                        HStack {
                            Text(filterDisplayLabel(filter))
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
                Text(L.tr("help"))
                    .font(.headline)
                    .padding()

                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        helpItem(L.tr("h_camera_preview"), L.tr("d_camera_preview"))
                        helpItem(L.tr("h_start_stop"),     L.tr("d_start_stop"))
                        helpItem(L.tr("h_resolution"),     L.tr("d_resolution"))
                        helpItem(L.tr("h_bitrate"),        L.tr("d_bitrate"))
                        helpItem(L.tr("h_fps"),            L.tr("d_fps"))
                        helpItem(L.tr("h_gop"),            L.tr("d_gop"))
                        helpItem(L.tr("h_codec"),          L.tr("d_codec"))
                        helpItem(L.tr("h_zoom"),           L.tr("d_zoom"))
                        helpItem(L.tr("h_exposure"),       L.tr("d_exposure"))
                        helpItem(L.tr("h_focus"),          L.tr("d_focus"))
                        helpItem(L.tr("h_wb"),             L.tr("d_wb"))
                        helpItem(L.tr("h_filter"),         L.tr("d_filter"))
                        helpItem(L.tr("h_audio"),          L.tr("d_audio"))
                        helpItem(L.tr("h_flash"),          L.tr("d_flash"))
                        helpItem(L.tr("h_flip"),           L.tr("d_flip"))
                        helpItem(L.tr("h_preview_off"),    L.tr("d_preview_off"))
                        helpItem(L.tr("h_perf"),           L.tr("d_perf"))
                        helpItem(L.tr("h_network"),        L.tr("d_network"))
                    }
                    .padding(.horizontal, 16)
                }

                Divider()

                Button(L.tr("close")) { showHelpDialog = false }
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
        VStack(alignment: .leading, spacing: 6) {
            // Header
            Text(L.tr("perf_title"))
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(Color(red: 1.0, green: 0.84, blue: 0.0)) // Gold
                .tracking(1.0)

            // Build version
            Text("V\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")（\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")）")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            
            // Section 1: System Resources
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 12) {
                    LabelValueView(label: "CPU", value: streamManager.perfCpu, color: .cyan)
                    LabelValueView(label: "MEM", value: streamManager.perfMem, color: .cyan)
                }
                HStack(spacing: 12) {
                    LabelValueView(label: "NET", value: streamManager.perfNet, color: .cyan)
                    LabelValueView(label: "BAT", value: streamManager.perfBat, color: .cyan)
                }
            }
            
            // Section 2: Streaming Telemetry (Only when client is connected)
            if streamManager.isClientConnected {
                Divider()
                    .background(Color.white.opacity(0.2))
                    .padding(.vertical, 2)
                
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 12) {
                        LabelValueView(
                            label: "FPS", 
                            value: String(format: "%.1f / %d", streamManager.currentFps, SettingsManager.shared.fps), 
                            color: streamManager.currentFps < Double(SettingsManager.shared.fps) * 0.9 ? .orange : .green
                        )
                        LabelValueView(
                            label: "ABR", 
                            value: String(format: "%.1f/%d M", streamManager.abrTargetBitrateMbps, SettingsManager.shared.bitrate), 
                            color: .green
                        )
                    }
                    HStack(spacing: 12) {
                        LabelValueView(
                            label: "LOSS", 
                            value: String(format: "%.1f%%", streamManager.currentLossPercent), 
                            color: streamManager.currentLossPercent > 2.0 ? .red : (streamManager.currentLossPercent > 0.0 ? .orange : .green)
                        )
                        LabelValueView(
                            label: "DROP", 
                            value: "\(streamManager.totalDroppedFrames)", 
                            color: streamManager.totalDroppedFrames > 0 ? .red : .white
                        )
                    }
                    LabelValueView(
                        label: "SENT", 
                        value: "\(streamManager.totalSentFrames)", 
                        color: .white
                    )
                }
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.white.opacity(0.15), lineWidth: 1)
                )
        )
        .padding(.top, 40)
        .padding(.leading, 8)
        .frame(maxWidth: 200, alignment: .topLeading)
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
                Text(L.tr("network_settings"))
                    .font(.headline)

                HStack {
                    Text(L.tr("rtsp_port"))
                        .frame(width: 80, alignment: .leading)
                    TextField("Port", text: $editPort)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }

                HStack {
                    Text(L.tr("rtsp_path"))
                        .frame(width: 80, alignment: .leading)
                    TextField("Path", text: $editPath)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 20) {
                    Button(L.tr("cancel")) { showNetworkDialog = false }
                        .keyboardShortcut(.cancelAction)
                    Button(L.tr("ok")) {
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

    /// Switch the interface language. Persists the choice, updates the in-memory lookup
    /// table language, and bumps uiLangId so SwiftUI rebuilds the entire view tree and
    /// every L.tr() call re-resolves (runtime switching, no app relaunch needed).
    private func setLanguage(_ code: String) {
        SettingsManager.shared.language = code
        L.language = SettingsManager.shared.resolvedLanguage
        uiLangId += 1
    }

    /// Map an internal white-balance preset value to its localized display label.
    /// The internal value (e.g. "INCANDESCENT") is still passed to applyWhiteBalancePreset.
    private func wbDisplayLabel(_ mode: String) -> String {
        switch mode {
        case "AUTO":        return L.tr("wb_auto")
        case "INCANDESCENT":return L.tr("wb_incandescent")
        case "FLUORESCENT": return L.tr("wb_fluorescent")
        case "DAYLIGHT":    return L.tr("wb_daylight")
        case "CLOUDY":      return L.tr("wb_cloudy")
        default:            return mode
        }
    }

    /// Map an internal filter value to its localized display label.
    private func filterDisplayLabel(_ filter: String) -> String {
        switch filter {
        case "None":  return L.tr("f_none")
        case "B&W":   return L.tr("f_bw")
        case "VIVID": return L.tr("f_vivid")
        case "WARM":  return L.tr("f_warm")
        case "COOL":  return L.tr("f_cool")
        default:      return filter
        }
    }

    private func startCameraPreview() {
        // Use the user's configured resolution for the preview session so that changing
        // RES is reflected immediately and the next streaming session starts at the right
        // format (previously this was hardcoded to 1280x720, which left the capture
        // session stuck at 720p even after the user selected 1080p/4K).
        let settings = SettingsManager.shared
        streamManager.cameraManager.configureSession(
            width: settings.getWidth(),
            height: settings.getHeight(),
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
