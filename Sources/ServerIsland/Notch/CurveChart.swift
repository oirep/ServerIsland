import SwiftUI

/// 详情页的小曲线（NEP loss / VASP 能量、最大力 / NEB 能垒图）。用 Path 直接画，离屏预览也能渲染。
/// 有 bars（NEB 每个像点的力）时：柱子用自己的纵轴（0 到最大值），只占图的下半部分，threshold 虚线画在柱子的纵轴上
/// 并在右端标"EDIFFG"，免得被看成能量；低于目标的柱子是绿色、高于的是琥珀色。
struct CurveChart: View {
    var curve: AppCurve
    /// 两张图并排时省掉右上角的"离子步 N"，标题行放得下。
    var compact = false
    static let colors: [Color] = [Theme.mint, Theme.cyan, Theme.amber, Theme.violet]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Text(curve.title).font(Theme.rounded(10.5, .semibold)).foregroundStyle(Theme.secondary).lineLimit(1).fixedSize()
                ForEach(Array(curve.series.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 4) {
                        if s.markers {
                            Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 5, height: 5)
                        } else {
                            Capsule().fill(Self.colors[i % Self.colors.count].opacity(s.faint ? 0.5 : 1)).frame(width: 9, height: 2.5)
                        }
                        Text(s.name).foregroundStyle(Theme.tertiary)
                        if !s.markers, let last = s.points.last {
                            Text(AppProgress.sci(Double(last.y))).foregroundStyle(Theme.secondary)
                        }
                    }
                    .font(Theme.rounded(9.5).monospacedDigit())
                    .fixedSize()
                }
                if let m = curve.bars.map(\.y).max() {
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.mint.opacity(0.5)).frame(width: 6, height: 8)
                        Text(curve.barsLabel).foregroundStyle(Theme.tertiary)
                        Text(AppProgress.sci(Double(m))).foregroundStyle(Theme.secondary)
                        if let t = curve.threshold {
                            Capsule().fill(Theme.amber.opacity(0.8)).frame(width: 9, height: 1.5)
                            Text(AppProgress.sci(t)).foregroundStyle(Theme.secondary)
                        }
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
                    Text(axisLabel(labelRange.max)); Spacer(minLength: 0); Text(axisLabel(labelRange.min))
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
                        // NEB：每个中间像点的力（柱子，自己的纵轴）
                        if !curve.bars.isEmpty {
                            let b = bounds, scale = barScale, area = geo.size.height * 0.5
                            let w = min(14, geo.size.width / CGFloat(max(curve.series.first?.points.count ?? 2, 2)) * 0.35)
                            ForEach(Array(curve.bars.enumerated()), id: \.offset) { _, bar in
                                let x = (bar.x - b.minX) / b.width * geo.size.width
                                let h = max(1, bar.y / scale * area)
                                let over = curve.threshold.map { Double(bar.y) > $0 } ?? false
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill((over ? Theme.amber : Theme.mint).opacity(0.32))
                                    .frame(width: w, height: h)
                                    .position(x: x, y: geo.size.height - h / 2)
                            }
                            if let t = curve.threshold {
                                let y = geo.size.height - CGFloat(t) / scale * area
                                Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width - 40, y: y)) }
                                    .stroke(Theme.amber.opacity(0.75), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
                                Text("EDIFFG").font(Theme.rounded(8, .semibold)).foregroundStyle(Theme.amber.opacity(0.85))
                                    .position(x: geo.size.width - 19, y: y)
                            }
                        }
                        if curve.bars.isEmpty, let t = curve.threshold {
                            let b = bounds
                            let y = geo.size.height - (ty(CGFloat(t)) - b.minY) / b.height * geo.size.height
                            Path { p in p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }
                                .stroke(Theme.amber.opacity(0.75), style: StrokeStyle(lineWidth: 0.9, dash: [3, 3]))
                        }
                        ForEach(Array(curve.series.enumerated()), id: \.offset) { i, s in
                            path(s.points, in: geo.size)
                                .stroke(Self.colors[i % Self.colors.count].opacity(s.faint ? 0.45 : 1),
                                        style: StrokeStyle(lineWidth: s.faint ? 1 : 1.3, lineJoin: .round, dash: s.faint ? [2, 2] : []))
                            if s.markers {
                                let b = bounds
                                ForEach(Array(s.points.enumerated()), id: \.offset) { _, pt in
                                    Circle().fill(Self.colors[i % Self.colors.count]).frame(width: 5, height: 5)
                                        .position(x: (pt.x - b.minX) / b.width * geo.size.width,
                                                  y: geo.size.height - (ty(pt.y) - b.minY) / b.height * geo.size.height)
                                }
                            }
                        }
                        // 收敛判据放在图的右上角（结构优化的力从左上往右下降，右上角通常是空的），图例那一行放不下。
                        if let label = criterionLabel {
                            HStack(spacing: 4) {
                                if curve.threshold != nil && curve.bars.isEmpty {
                                    Capsule().fill(Theme.amber.opacity(0.8)).frame(width: 9, height: 1.5)
                                }
                                Text(label)
                            }
                            .font(Theme.rounded(9).monospacedDigit())
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.card.opacity(0.9)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .help(!curve.bars.isEmpty
                                  ? L("能垒 = 最高的像点 − 初态（00），和 VTST 的 nebef.pl 一样用 energy(sigma→0)。柱子是每个中间像点的最大力（VTST），虚线是 |EDIFFG|：所有柱子都低于虚线时 NEB 收敛。",
                                      "Barrier = highest image − initial state (00), using energy(sigma→0) like VTST's nebef.pl. Bars are each image's max force (VTST); the dashed line is |EDIFFG| — NEB has converged when every bar is below it.")
                                  : curve.note != nil
                                  ? L("这次结构优化按能量收敛（EDIFFG ≥ 0 或没写，VASP 默认 0.001），最大力不是停止条件，所以没有目标线。",
                                      "This relaxation stops on energy (EDIFFG ≥ 0 or unset; VASP's default is 0.001), so the max force isn't the stopping rule and there's no target line.")
                                  : L("EDIFFG < 0：所有原子的受力都小于这个值时优化结束（虚线）。", "EDIFFG < 0: the relaxation ends when every force is below this value (dashed line)."))
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
    }

    /// 收敛判据：按能量（note）或按力（threshold，配虚线）。
    private var criterionLabel: String? {
        if let n = curve.note { return n }
        if !curve.bars.isEmpty { return nil }   // NEB 的目标线在柱子上，图例里已经写了
        if let t = curve.threshold { return L("按力收敛 < \(AppProgress.sci(t)) eV/Å", "force criterion < \(AppProgress.sci(t)) eV/Å") }
        return nil
    }

    private func ty(_ y: CGFloat) -> CGFloat { curve.logY ? log10(max(y, 1e-12)) : y }

    /// 纵轴上标的两个数：一般是上下边界；带圆点的曲线（NEB）留了空白，标真实的最高 / 最低值。
    private var labelRange: (min: CGFloat, max: CGFloat) {
        let b = bounds
        guard curve.series.contains(where: \.markers) else { return (b.minY, b.maxY) }
        let ys = curve.series.flatMap(\.points).map { ty($0.y) }
        return (ys.min() ?? b.minY, ys.max() ?? b.maxY)
    }

    /// 柱子的纵轴：0 到（最大的柱子和目标值里大的那个）再留一点空。
    private var barScale: CGFloat {
        max(curve.bars.map(\.y).max() ?? 0, CGFloat(curve.threshold ?? 0), 1e-12) * 1.15
    }

    /// 所有曲线共用的范围（已经换算到对数坐标时是指数）。有柱子时 threshold 属于柱子的纵轴，不算在内。
    private var bounds: CGRect {
        let pts = curve.series.flatMap(\.points)
        guard let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max() else { return .zero }
        let ys = pts.map { ty($0.y) } + (curve.bars.isEmpty ? (curve.threshold.map { [ty(CGFloat($0))] } ?? []) : [])
        var y0 = ys.min() ?? 0, y1 = ys.max() ?? 1
        if y1 - y0 < 1e-9 { y0 -= 0.5; y1 += 0.5 }
        // 带圆点的曲线（NEB）上下留一点空，最高点的圆点不被裁掉
        if curve.series.contains(where: \.markers) { let pad = (y1 - y0) * 0.1; y0 -= pad; y1 += pad }
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
