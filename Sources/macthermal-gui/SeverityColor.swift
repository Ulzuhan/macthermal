import AppKit
import SwiftUI
#if canImport(MacThermalCore)
import MacThermalCore
#endif

/// Severity tints that stay legible as coloured text.
///
/// The system colours these replace are tuned for fills and for dark
/// backgrounds, not for text on a light one. Measured against the two
/// backgrounds this app actually draws on in light mode, every one of them
/// failed WCAG AA (4.5:1 for normal text) and three failed even the 3:1
/// large-text floor:
///
///     yellow 1.35:1 · orange 1.97:1 · green 1.99:1 · red 3.18:1   (on #F2F2F7)
///
/// `warn` — the worst of them — is the 78–90 °C band, so the most common
/// elevated reading was the least readable. These keep the same hues and clear
/// 4.5:1 in both appearances (light 4.85–5.51, dark 4.94–9.75 on a GroupBox).
///
/// Built from a dynamic `NSColor` rather than an asset catalog because the flat
/// `swiftc` build has nowhere to put an xcassets bundle. Defining them here
/// means every existing `severity.color` / `level.color` call site is fixed
/// without changing one of them.
private enum SeverityPalette {
    static let green = tint(light: 0x1D7A33, dark: 0x30D158)
    static let amber = tint(light: 0x8A6100, dark: 0xFFD426)
    static let orange = tint(light: 0xA34700, dark: 0xFF9F0A)
    static let red = tint(light: 0xC2122B, dark: 0xFF6961)

    private static func tint(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark)
                : NSColor(rgb: light)
        })
    }
}

private extension NSColor {
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Severity {
    var color: Color {
        switch self {
        case .ok, .normal: SeverityPalette.green
        case .warn: SeverityPalette.amber
        case .hot: SeverityPalette.orange
        case .critical: SeverityPalette.red
        }
    }

    var symbol: String {
        switch self {
        case .ok, .normal: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .hot: "flame.fill"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}

extension ThrottleLevel {
    var color: Color {
        switch self {
        case .normal: SeverityPalette.green
        case .elevated: SeverityPalette.amber
        case .active: SeverityPalette.orange
        case .critical: SeverityPalette.red
        }
    }

    var symbol: String {
        switch self {
        case .normal: "checkmark.shield.fill"
        case .elevated: "thermometer.high"
        case .active: "gauge.with.dots.needle.67percent"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}
