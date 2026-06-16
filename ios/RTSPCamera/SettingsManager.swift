import Foundation

class SettingsManager {
    static let shared = SettingsManager()
    
    let defaults = UserDefaults.standard
    
    private init() {}
    
    var resolution: String {
        get { defaults.string(forKey: "resolution") ?? "1280x720" }
        set { defaults.set(newValue, forKey: "resolution") }
    }
    
    var fps: Int {
        get { defaults.integer(forKey: "fps") == 0 ? 30 : defaults.integer(forKey: "fps") }
        set { defaults.set(newValue, forKey: "fps") }
    }
    
    var bitrate: Int {
        get { defaults.integer(forKey: "bitrate") == 0 ? 30 : defaults.integer(forKey: "bitrate") }
        set { defaults.set(newValue, forKey: "bitrate") } // in Mbps
    }
    
    var gop: Int {
        get { defaults.integer(forKey: "gop") == 0 ? 30 : defaults.integer(forKey: "gop") }
        set { defaults.set(newValue, forKey: "gop") }
    }
    
    var rtspPort: Int {
        get { defaults.integer(forKey: "rtspPort") == 0 ? 9527 : defaults.integer(forKey: "rtspPort") }
        set { defaults.set(newValue, forKey: "rtspPort") }
    }
    
    var rtspPath: String {
        get { defaults.string(forKey: "rtspPath") ?? "/live" }
        set { defaults.set(newValue, forKey: "rtspPath") }
    }
    
    var videoCodec: String {
        get { defaults.string(forKey: "videoCodec") ?? "h264" }
        set { defaults.set(newValue, forKey: "videoCodec") }
    }
    
    var audioEnabled: Bool {
        get { defaults.object(forKey: "audioEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "audioEnabled") }
    }
    
    var previewEnabled: Bool {
        get { defaults.object(forKey: "previewEnabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "previewEnabled") }
    }
    
    var language: String {
        get { defaults.string(forKey: "language") ?? "auto" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Resolve "auto" → first preferredLanguage matching zh/en → "en".
    var resolvedLanguage: String {
        if language != "auto" { return language }
        let pref = Locale.preferredLanguages.first ?? "en"
        if pref.hasPrefix("zh") { return "zh" }
        return "en"
    }

    var perfMonitorEnabled: Bool {
        get { defaults.bool(forKey: "perfMonitorEnabled") }
        set { defaults.set(newValue, forKey: "perfMonitorEnabled") }
    }

    // MARK: - Resolution Helpers

    /// Device-validated resolution entries with aspect-ratio labels (matching Android).
    /// Updated by CameraManager when the capture device changes.
    func supportedResolutions(caps: CameraCapabilities) -> [ResolutionEntry] {
        caps.resolvedResolutions
    }

    /// Build the display labels for the RES dropdown (e.g. "4K 16:9 (3840x2160)").
    func resolutionDisplayLabel(for entry: ResolutionEntry) -> String {
        "\(entry.label) (\(entry.width)x\(entry.height))"
    }
    
    func getWidth() -> Int {
        let parts = resolution.split(separator: "x")
        if parts.count == 2, let width = Int(parts[0]) {
            return width
        }
        return 1280
    }
    
    func getHeight() -> Int {
        let parts = resolution.split(separator: "x")
        if parts.count == 2, let height = Int(parts[1]) {
            return height
        }
        return 720
    }
}
