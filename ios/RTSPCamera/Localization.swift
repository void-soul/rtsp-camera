import Foundation

// MARK: - Lightweight i18n string table
//
// Provides a tiny translation layer without relying on SwiftUI's system localization
// (which would require bundle-based .strings files and a relaunch to switch languages).
// Instead we keep a [key: [lang: value]] table and resolve against the user's chosen
// language at call time. Switching the language just flips a @State that forces the view
// tree to re-render with new strings. Mirrors Android's runtime locale switching.

enum AppLanguage: String {
    case auto, zh, en

    /// Resolve "auto" to a concrete language using the device's preferred language.
    var resolved: String {
        switch self {
        case .auto:
            let preferredLangs = Locale.preferredLanguages
            // e.g. "zh-Hans-CN" -> "zh"
            if let first = preferredLangs.first, first.hasPrefix("zh") { return "zh" }
            return "en"
        case .zh: return "zh"
        case .en: return "en"
        }
    }
}

enum L {
    /// Current active language code ("zh" or "en"). Set by the UI when the user picks
    /// a language; read by `tr()` on every string lookup.
    static var language: String = SettingsManager.shared.resolvedLanguage

    /// English / Chinese translations keyed by a stable identifier.
    /// Only user-visible strings are listed here; technical labels (RES/BITRATE/FPS/GOP/
    /// CODEC, abbreviations like CPU/MEM/NET/BAT) intentionally stay in English on both.
    private static let table: [String: [String: String]] = [
        "press_to_start":   ["en": "Press play to start streaming", "zh": "点击播放按钮开始推流"],
        "network_settings": ["en": "Network Settings",              "zh": "网络设置"],
        "rtsp_port":        ["en": "RTSP Port",                     "zh": "RTSP 端口"],
        "rtsp_path":        ["en": "RTSP Path",                     "zh": "RTSP 路径"],
        "cancel":           ["en": "Cancel",                        "zh": "取消"],
        "ok":               ["en": "OK",                            "zh": "确定"],
        "help":             ["en": "Help",                          "zh": "帮助"],
        "close":            ["en": "Close",                         "zh": "关闭"],
        "url_copied":       ["en": "URL Copied",                    "zh": "地址已复制"],
        "white_balance":    ["en": "White Balance",                 "zh": "白平衡"],
        "filter":           ["en": "Filter",                        "zh": "滤镜"],
        "continuous_af":    ["en": "Continuous Auto Focus",         "zh": "持续自动对焦"],

        // Help items
        "h_camera_preview": ["en": "Camera Preview", "zh": "相机预览"],
        "h_start_stop":     ["en": "Start/Stop",     "zh": "开始/停止"],
        "h_resolution":     ["en": "Resolution",     "zh": "分辨率"],
        "h_bitrate":        ["en": "Bitrate",        "zh": "码率"],
        "h_fps":            ["en": "Frame Rate",     "zh": "帧率"],
        "h_gop":            ["en": "Keyframe Interval", "zh": "关键帧间隔"],
        "h_codec":          ["en": "Codec",          "zh": "编码格式"],
        "h_zoom":           ["en": "Zoom",           "zh": "变焦"],
        "h_exposure":       ["en": "Exposure",       "zh": "曝光"],
        "h_focus":          ["en": "Focus",          "zh": "对焦"],
        "h_wb":             ["en": "White Balance",  "zh": "白平衡"],
        "h_filter":         ["en": "Filter",         "zh": "滤镜"],
        "h_audio":          ["en": "Audio",          "zh": "音频"],
        "h_flash":          ["en": "Flash",          "zh": "闪光灯"],
        "h_flip":           ["en": "Camera Flip",    "zh": "切换镜头"],
        "h_preview_off":    ["en": "Preview Off",    "zh": "关闭预览"],
        "h_perf":           ["en": "Performance",    "zh": "性能监控"],
        "h_network":        ["en": "Network Settings", "zh": "网络设置"],

        "d_camera_preview": ["en": "Always visible. Toggle with eye icon in top bar.", "zh": "始终可见，用顶部栏的眼睛图标切换。"],
        "d_start_stop":     ["en": "Red button on right edge starts/stops RTSP streaming.", "zh": "右侧红色按钮开始/停止 RTSP 推流。"],
        "d_resolution":     ["en": "Tap RES to change (4K/1080p/720p).", "zh": "点击 RES 切换分辨率 (4K/1080p/720p)。"],
        "d_bitrate":        ["en": "Tap BITRATE to adjust (5-60 Mbps).", "zh": "点击 BITRATE 调整码率 (5-60 Mbps)。"],
        "d_fps":            ["en": "Tap FPS to set frame rate (24/30/60/120).", "zh": "点击 FPS 设置帧率 (24/30/60/120)。"],
        "d_gop":            ["en": "Tap GOP to set keyframe interval.", "zh": "点击 GOP 设置关键帧间隔。"],
        "d_codec":          ["en": "Tap CODEC to switch H.264/H.265 (only when not streaming).", "zh": "点击 CODEC 切换 H.264/H.265（仅未推流时）。"],
        "d_zoom":           ["en": "Tap ZOOM, then use slider (1x-10x).", "zh": "点击变焦，然后用滑块 (1x-10x)。"],
        "d_exposure":       ["en": "Tap EV, then use slider (-3 to +3).", "zh": "点击曝光，然后用滑块 (-3 到 +3)。"],
        "d_focus":          ["en": "Tap FOCUS, then AF/MF toggle + slider.", "zh": "点击对焦，切换自动/手动 + 滑块。"],
        "d_wb":             ["en": "Tap WB for presets.", "zh": "点击白平衡选择预设。"],
        "d_filter":         ["en": "Tap FILTER for effects.", "zh": "点击滤镜选择效果。"],
        "d_audio":          ["en": "Toggle microphone with speaker icon.", "zh": "用扬声器图标开关麦克风。"],
        "d_flash":          ["en": "Toggle torch with flashlight icon.", "zh": "用闪光灯图标开关手电筒。"],
        "d_flip":           ["en": "Switch front/back with rotate icon.", "zh": "用旋转图标切换前后镜头。"],
        "d_preview_off":    ["en": "Hide preview to save battery.", "zh": "隐藏预览以省电。"],
        "d_perf":           ["en": "Toggle HUD with chart icon.", "zh": "用图表图标切换性能面板。"],
        "d_network":        ["en": "Change RTSP port and path with network icon.", "zh": "用网络图标修改 RTSP 端口和路径。"],

        // Performance HUD title
        "perf_title":       ["en": "PERFORMANCE MONITOR", "zh": "性能监控"],

        // Filters / White balance presets (short labels)
        "f_none":           ["en": "None",        "zh": "原图"],
        "f_bw":             ["en": "B&W",         "zh": "黑白"],
        "f_vivid":          ["en": "VIVID",       "zh": "鲜艳"],
        "f_warm":           ["en": "WARM",        "zh": "暖色"],
        "f_cool":           ["en": "COOL",        "zh": "冷色"],
        "wb_auto":          ["en": "AUTO",        "zh": "自动"],
        "wb_incandescent":  ["en": "INCANDESCENT","zh": "白炽灯"],
        "wb_fluorescent":   ["en": "FLUORESCENT", "zh": "荧光灯"],
        "wb_daylight":      ["en": "DAYLIGHT",    "zh": "日光"],
        "wb_cloudy":        ["en": "CLOUDY",      "zh": "多云"],
    ]

    /// Translate a key for the current language. Falls back to English, then the key.
    static func tr(_ key: String) -> String {
        if let entry = table[key] {
            return entry[language] ?? entry["en"] ?? key
        }
        return key
    }
}

// MARK: - SettingsManager language support
extension SettingsManager {
    /// Stored language preference: "auto", "zh", or "en".
    var language: String {
        get { defaults.string(forKey: "language") ?? "auto" }
        set { defaults.set(newValue, forKey: "language") }
    }

    /// Resolve the stored preference to a concrete language code ("zh"/"en").
    var resolvedLanguage: String {
        return AppLanguage(rawValue: language)?.resolved ?? "en"
    }
}
