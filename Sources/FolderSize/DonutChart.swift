import SwiftUI

/// 环形图的一个扇区
struct PieSlice: Identifiable {
    let name: String
    let value: Int64
    let color: Color
    var id: String { name }
}

/// 环形图(细环 + 2px 表面间隔 + 中心合计)
struct DonutChart: View {
    let slices: [PieSlice]
    let total: Int64

    var body: some View {
        Canvas { ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let outer = min(size.width, size.height) / 2 - 2
            let inner = outer * 0.62
            let surface = Color(nsColor: .windowBackgroundColor)

            if slices.isEmpty || total <= 0 {
                let p = Path(ellipseIn: CGRect(
                    x: center.x - outer, y: center.y - outer,
                    width: outer * 2, height: outer * 2
                ))
                ctx.fill(p, with: .color(Color.gray.opacity(0.15)))
            } else {
                let denominator = max(1, total)
                var start = Angle.degrees(-90)
                for slice in slices where slice.value > 0 {
                    let sweep = Angle.degrees(360 * Double(slice.value) / Double(denominator))
                    var path = Path()
                    path.addArc(center: center, radius: outer, startAngle: start, endAngle: start + sweep, clockwise: false)
                    path.addArc(center: center, radius: inner, startAngle: start + sweep, endAngle: start, clockwise: true)
                    path.closeSubpath()
                    ctx.fill(path, with: .color(slice.color))
                    // 2px 表面色间隔分隔相邻扇区
                    ctx.stroke(path, with: .color(surface), lineWidth: 2)
                    start += sweep
                }
            }

            ctx.draw(
                Text(Format.size(total))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary),
                at: CGPoint(x: center.x, y: center.y - 8)
            )
            ctx.draw(
                Text(L.t("detail.total"))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary),
                at: CGPoint(x: center.x, y: center.y + 11)
            )
        }
        .frame(height: 180)
        .accessibilityLabel(L.t("detail.donutA11y"))
    }
}

/// 图例行里的迷你占比条(细条,同色系浅底)
struct MiniBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule()
                    .fill(color)
                    .frame(width: min(geo.size.width, max(3, geo.size.width * fraction)))
            }
        }
        .frame(height: 4)
    }
}
