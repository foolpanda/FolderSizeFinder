import SwiftUI
import AppKit

enum Format {
    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.isAdaptive = true
        return f
    }()

    static func size(_ v: Int64) -> String {
        byteFormatter.string(fromByteCount: max(0, v))
    }

    static func count(_ n: Int) -> String {
        n.formatted(.number.grouping(.automatic))
    }

    /// 百分比;过小显示 "<0.1%"
    static func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "—" }
        let pct = Double(value) / Double(total) * 100
        if pct < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", pct)
    }

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }
}

// MARK: - 图表色板(dataviz 参考色板:固定顺序,浅/深两套)

enum NSColorHex {
    static func ns(_ hex: String) -> NSColor {
        var v: UInt64 = 0
        Scanner(string: String(hex.dropFirst())).scanHexInt64(&v)
        return NSColor(
            srgbRed: Double((v >> 16) & 0xFF) / 255,
            green: Double((v >> 8) & 0xFF) / 255,
            blue: Double(v & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    /// 跟随系统外观的动态颜色
    static func dynamic(_ lightHex: String, _ darkHex: String) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColorHex.ns(isDark ? darkHex : lightHex)
        }))
    }
}

enum Viz {
    /// 分类色,固定顺序,不循环;第 8 槽起折入"其他"
    static let categorical: [(light: String, dark: String)] = [
        ("#2a78d6", "#3987e5"),  // 1 blue
        ("#eb6834", "#d95926"),  // 2 orange
        ("#1baf7a", "#199e70"),  // 3 aqua
        ("#eda100", "#c98500"),  // 4 yellow
        ("#e87ba4", "#d55181"),  // 5 magenta
        ("#008300", "#008300"),  // 6 green
        ("#4a3aa7", "#9085e9"),  // 7 violet
    ]
    /// "其他"用中性灰
    static let other = (light: "#898781", dark: "#898781")

    static func sliceColor(_ index: Int) -> Color {
        guard index >= 0, index < categorical.count else {
            return Color.dynamic(other.light, other.dark)
        }
        let slot = categorical[index]
        return Color.dynamic(slot.light, slot.dark)
    }
}
