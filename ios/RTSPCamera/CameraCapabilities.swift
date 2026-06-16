import Foundation
import AVFoundation

/// A resolution entry with human-readable label matching Android's style.
struct ResolutionEntry {
    let width: Int
    let height: Int
    let label: String      // e.g. "4K 16:9"
    let aspectRatio: String // e.g. "16:9"

    var resolutionKey: String { "\(width)x\(height)" }
}

/// Device camera capabilities queried from AVCaptureDevice.
/// - resolvedResolutions: device-validated resolution list with labels
/// - supportedWbModes: AWB modes the device actually supports
/// - supportedEffects: effect/filter modes (iOS has no Camera2-style effects; we map WB presets)
class CameraCapabilities {
    private(set) var resolvedResolutions: [ResolutionEntry] = []
    private(set) var supportedWbModes: Set<AVCaptureDevice.WhiteBalanceMode> = []
    private(set) var supportedWbPresets: Set<String> = []

    /// Device zoom range (e.g. 0.5x on devices with ultra-wide lens, 1.0x otherwise).
    let minZoom: CGFloat
    let maxZoom: CGFloat

    /// All possible resolutions the app can offer, in the same order as Android's
    /// `arrays.xml`. Each is validated against the device's activeFormat list.
    private static let candidateResolutions: [(Int, Int, String, String)] = [
        (3840, 2160, "4K 16:9",   "16:9"),
        (4032, 3024, "12MP 4:3",  "4:3"),
        (2560, 1440, "2K 16:9",   "16:9"),
        (2560, 1920, "5MP 4:3",   "4:3"),
        (1920, 1080, "1080p 16:9","16:9"),
        (1280, 720,  "720p 16:9", "16:9"),
        (1280, 960,  "SXGA 4:3",  "4:3"),
        (640,  480,  "VGA 4:3",   "4:3"),
    ]

    init(device: AVCaptureDevice) {
        self.minZoom = device.minAvailableVideoZoomFactor
        self.maxZoom = min(device.maxAvailableVideoZoomFactor, 10.0)
        resolveResolutions(device: device)
        resolveWhiteBalance(device: device)
    }

    // MARK: - Resolution Detection

    private func resolveResolutions(device: AVCaptureDevice) {
        // Build a quick-lookup set of available pixel counts for fast filtering.
        // We use pixel count rather than exact dimensions because AVCaptureDevice
        // formats often report slightly different widths for the same nominal
        // resolution (e.g. 1920 vs 1922).
        var availablePixelCounts = Set<Int>()
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            availablePixelCounts.insert(Int(dims.width) * Int(dims.height))
        }

        let maxPixels = availablePixelCounts.max() ?? (1920 * 1080)

        for (w, h, label, ar) in Self.candidateResolutions {
            let targetPixels = w * h
            // Only include resolutions the device can actually deliver.
            // Allow ±15% tolerance for format variations.
            let tolerance = targetPixels / 7
            let found = availablePixelCounts.contains { abs($0 - targetPixels) <= tolerance }
            if found || targetPixels <= maxPixels {
                resolvedResolutions.append(ResolutionEntry(width: w, height: h, label: label, aspectRatio: ar))
            }
        }
    }

    // MARK: - White Balance Detection

    private func resolveWhiteBalance(device: AVCaptureDevice) {
        // ContinuousAutoWhiteBalance is always supported.
        supportedWbModes.insert(.continuousAutoWhiteBalance)

        if device.isWhiteBalanceModeSupported(.locked) {
            supportedWbModes.insert(.locked)
        }

        // Map AVCaptureDevice modes to our preset strings (matching Android).
        // iOS doesn't have named WB presets like Android's CONTROL_AWB_MODE_DAYLIGHT,
        // but we expose the presets as UI categories. All get mapped to .continuousAutoWhiteBalance
        // in CameraManager.applyWhiteBalancePreset(). We still filter unsupported modes
        // so the UI is consistent with Android.
        supportedWbPresets = ["AUTO"]

        // On iOS, locked mode means we can set custom gains — treat as
        // "manual" WB capability.
        if device.isWhiteBalanceModeSupported(.locked) {
            supportedWbPresets.formUnion(["INCANDESCENT", "FLUORESCENT", "DAYLIGHT", "CLOUDY"])
        }
    }

    /// Whether a given white balance preset is supported by this device.
    func isWbPresetSupported(_ preset: String) -> Bool {
        supportedWbPresets.contains(preset)
    }

    // MARK: - Helpers

    /// Best matching ResolutionEntry for a given resolution key, falling back to the
    /// first entry.
    func bestMatch(for key: String) -> ResolutionEntry {
        resolvedResolutions.first { $0.resolutionKey == key } ?? resolvedResolutions.first!
    }
}
