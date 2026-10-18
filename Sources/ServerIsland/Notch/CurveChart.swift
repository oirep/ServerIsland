import SwiftUI

/// 详情页的小曲线（NEP loss / VASP 能量）。用 Path 直接画，离屏预览也能渲染。
struct CurveChart: View {
    var curve: AppCurve
    /// 两张图并排时省掉右上角的"离子步 N"，标题行放得下。
    var compact = false
    static let colors: [Color] = [Theme.mint, Theme.cyan, Theme.amber, Theme.violet]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 10) {
                Text(curve.title).font(Theme.rounded(10.5, .semibold)).foregroundStyle(Theme.secondary)
                ForEach(Array(curve.series.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 4) {
                        Capsule().fill(Self.colors[i % Self.colors.count]).frame(width: 9, height: 2.5)
                        Text(s.name).foregroundStyle(Theme.tertiary)
                        if let last = s.points.last {
                            Text(AppProgress.sci(Double(last.y))).foregroundStyle(Theme.secondary)
                        }
                    }
                    .font(Theme.rounded(9.5).monospacedDigit())
                    .fixedSize()
                }
                if let t = curve.threshold {
                    HStack(spacing: 4) {
                        Capsule().fill(Theme.amber.opacity(0.8)).frame(width: 9, height: 1.5)
                        Text(L("目标", "target")).foregroundStyle(Theme.tertiary)
                        Text(AppProgress.sci(t)).foregroundStyle(Theme.secondary)
                    }
                    .font(Theme.rounded(9.5).monospacedDigit())
                    .fixedSize()
                }
                Spacer(minLength: 0)
                if !compact, let x = curve.series.first?.points.last?.x {
                    Text(curve.xLabel + " " + AppProgress.compact(Double(x)))
                        .font(Theme.rounded(9.5).monospacedDigit()).foregroundStyle(Theme.tertiary)
                }
            }
            HStack(spacing: 6) {
                VStack(alignment: .trailing) {
                    Text(axisLabel(bounds.maxY)); Spacer(minLength: 0); Text(axisLabel(bounds.minY))
                }
                .font(Theme.mono(8.5)).foregroundStyle(Theme.tertiary)
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(width: 46, alignment: .trailing)
                GeometryReader { geo in
                    ZStack {
                        // 横向参考线
                        Path { p in
                            for k in 0...2 {
                                let y = geo.size.height * CGFloat(k) / 2
                                p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.06), lineWidth: 0.5)
                        if let t = curve.threshold {
                            let b = bounds
                            let y = geo.size.height - (ty(CGFloat(t)) - b.minY) / b.height * geo.size.height
                            Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                                .stroke(Theme.amber.opacity(0.75), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
                        }
                        ForEach(Array(curve.series.enumerated()), id: \.offset) { i, s in
                            path(s.points, in: geo.size)
                                .stroke(Self.colors[i % Self.colors.count], style: StrokeStyle(lineWidth: 1.3, lineJoin: .round))
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    private func ty(_ y: CGFloat) -> CGFloat { curve.logY ? log10(max(y, 1e-12)) : y }

    /// 所有曲线共用的范围（已经换算到对数坐标时是指数）。
    private var bounds: CGRect {
        let pts = curve.series.flatMap(\.points)
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max() else { return .zero }
        let ys = pts.map { ty($0.y) } + (curve.threshold.map { [ty(CGFloat($0))] } ?? [])
        var y0 = ys.min() ?? 0, y1 = ys.max() ?? 1
        if y1 - y0 < 1e-9 { y0 -= 0.5; y1 += 0.5 }
        return CGRect(x: x0, y: y0, width: max(x1 - x0, 1e-9), height: y1 - y0)
    }

    private func path(_ pts: [CGPoint], in size: CGSize) -> Path {
        let b = bounds
        return Path { p in
            for (i, pt) in pts.enumerated() {
                let x = (pt.x - b.minX) / b.width * size.width
                let y = size.height - (ty(pt.y) - b.minY) / b.height * size.height
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
    }

    private func axisLabel(_ v: CGFloat) -> String {
        if curve.logY { return AppProgress.sci(pow(10, Double(v))) }
        let a = abs(Double(v))
        if a >= 100 { return String(format: "%.1f", Double(v)) }
        if a >= 1 { return String(format: "%.2f", Double(v)) }
        return AppProgress.sci(Double(v))
    }
}
