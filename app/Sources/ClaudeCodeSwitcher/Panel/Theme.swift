import SwiftUI

/// Fixed visual identity (BUILD_PLAN.md section 7): one deliberately-designed appearance, not a
/// customization surface. The only variation is automatic light/dark matched to the system.
/// There is no user-facing theme picker anywhere in this app.
enum Theme {
    static let accent = Color(light: "#5B5BD6", dark: "#8B8BF0")
    static let surface = Color(light: "#FFFFFF", dark: "#1C1C22")
    static let surface2 = Color(light: "#F4F4F8", dark: "#26262E")
    static let text = Color(light: "#1A1A22", dark: "#ECECF2")
    static let textDim = Color(light: "#6B6B76", dark: "#9A9AA6")
    static let ok = Color(light: "#2F9E6B", dark: "#46C88A")
    static let warn = Color(light: "#D9942B", dark: "#F0B44A")
    static let crit = Color(light: "#D14D57", dark: "#F06A72")

    static func usageColor(forPct pct: Double) -> Color {
        switch pct {
        case ..<60: return ok
        case 60..<85: return warn
        default: return crit
        }
    }
}

private extension Color {
    init(light: String, dark: String) {
        self.init(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value & 0xFF0000) >> 16) / 255.0
        let g = Double((value & 0x00FF00) >> 8) / 255.0
        let b = Double(value & 0x0000FF) / 255.0
        self.init(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
