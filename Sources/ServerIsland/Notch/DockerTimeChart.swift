import SwiftUI
import Charts

/// 曲线只使用真实采样；实时横轴与时间切换器分开更新。
enum DockerChartMetric: Int, CaseIterable, Identifiable {
    case cpu, memory, network, blockIO
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return L("内存", "Memory")
        case .network: return L("网络", "Network")
        case .blockIO: return L("磁盘 I/O", "Block I/O")
        }
    }
    var unit: String { self == .cpu ? "%" : self == .memory ? "MiB" : "KiB/s" }
}

struct DockerChartSample: Identifiable, Equatable {
    var id: String
    var time: Date
    var value: Double
    var series: Int
    var segment: String
}

enum DockerChartData {
    /// 横轴随界面时钟推进；容忍服务器时钟略快，避免丢掉刚采集到的点。
    static func end(points: [DockerMetricPoint], now: Date) -> Date {
        max(now, points.last.map { Date(timeIntervalSince1970: $0.time) } ?? now)
    }

    static func samples(points: [DockerMetricPoint], metric: DockerChartMetric, window: Int, interval: Double, end: Date? = nil) -> [DockerChartSample] {
        guard let end = end?.timeIntervalSince1970 ?? points.last?.time else { return [] }
        let filtered = points.filter { $0.time >= end - Double(window) && $0.time <= end }
        let values: [(DockerMetricPoint) -> Double?]
        switch metric {
        case .cpu: values = [{ $0.cpu }]
        case .memory: values = [{ $0.memory.map { $0 / 1_048_576 } }]
        case .network: values = [{ $0.rx.map { $0 / 1024 } }, { $0.tx.map { $0 / 1024 } }]
        case .blockIO: values = [{ $0.read.map { $0 / 1024 } }, { $0.write.map { $0 / 1024 } }]
        }
        var result: [DockerChartSample] = []
        for (series, value) in values.enumerated() {
            var segment = 0
            var previous: Double?
            for point in filtered {
                guard let amount = value(point), amount.isFinite else {
                    segment += 1; previous = nil; continue
                }
                if let previous, point.time - previous > max(150, interval * 3) { segment += 1 }
                result.append(DockerChartSample(id: "\(series)|\(point.time)",
                                                time: Date(timeIntervalSince1970: point.time), value: amount,
                                                series: series, segment: "\(series)|\(segment)"))
                previous = point.time
            }
        }
        return result
    }
}

/// 四图共用时间范围，但各图保留独立读数；固定尺寸避免新数据、空状态和图例引起跳动。
struct DockerTimeChart: View {
    var points: [DockerMetricPoint]
    var now: Date
    var interval: Double = 60
    @State private var window = 180

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(L("时序指标", "Time Series")).font(Theme.rounded(10.5, .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                DockerRangeSelector(selected: window, labelPrefix: L("时间范围 ", "Time range ")) { window = $0 }
                    .equatable()
            }
            .frame(height: 24)
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { panel(.cpu); panel(.memory) }
                GridRow { panel(.network); panel(.blockIO) }
            }
        }
        // 外层面板有弹簧动画；采样更新和范围切换不继承它，防止坐标/按钮被重复插值。
        .transaction { $0.animation = nil }
    }

    private func panel(_ metric: DockerChartMetric) -> some View {
        let end = DockerChartData.end(points: points, now: now)
        return DockerMiniChart(metric: metric,
                               samples: DockerChartData.samples(points: points, metric: metric, window: window, interval: interval, end: end),
                               end: end, window: window)
    }
}

/// 仅选中范围变化才更新按钮，父页面的秒级时钟和采样变化不会重建切换器。
struct DockerRangeSelector: View, Equatable {
    var selected: Int
    var labelPrefix: String
    var onSelect: (Int) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected && lhs.labelPrefix == rhs.labelPrefix }

    var body: some View {
        HStack(spacing: 0) {
            ForEach([60, 180, 300, 600], id: \.self) { seconds in
                Button {
                    onSelect(seconds)
                } label: {
                    Text("\(seconds / 60)m")
                        .font(Theme.rounded(10, .medium))
                        .foregroundStyle(selected == seconds ? Theme.text : Theme.tertiary)
                        .frame(width: 43, height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(selected == seconds ? Color.white.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DockerToolbarHover())
                .accessibilityLabel(labelPrefix + "\(seconds / 60)m")
                .accessibilityAddTraits(selected == seconds ? [.isSelected] : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
        .frame(width: 176, height: 24)
        .fixedSize()
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
    }
}

private struct DockerMiniChart: View {
    var metric: DockerChartMetric
    var samples: [DockerChartSample]
    var end: Date
    var window: Int
    @State private var selection: Date?

    private var inspected: DockerChartSample? {
        guard let selection else { return nil }
        return samples.min { abs($0.time.timeIntervalSince(selection)) < abs($1.time.timeIntervalSince(selection)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(metric.title).font(Theme.rounded(10.5, .semibold)).foregroundStyle(Theme.secondary)
                Spacer(minLength: 0)
                Text(metric.unit).font(Theme.mono(8.5)).foregroundStyle(Theme.tertiary)
            }
            .frame(height: 13)
            Group {
                if samples.isEmpty {
                    Text(L("等待有效采样", "Waiting for samples"))
                        .font(Theme.rounded(10)).foregroundStyle(Theme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart
                }
            }
            .frame(height: 84)
            summary.frame(height: 12, alignment: .leading)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 140)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.085)))
        .onChange(of: window) { _ in selection = nil }
    }

    @ViewBuilder
    private var summary: some View {
        if let inspected {
            Text(inspected.time.formatted(date: .omitted, time: .shortened) + " · " + String(format: "%.2f", inspected.value) + " " + metric.unit)
                .font(Theme.mono(8.5)).foregroundStyle(Theme.secondary).lineLimit(1)
        } else {
            HStack(spacing: 7) {
                ForEach(metric == .network || metric == .blockIO ? [0, 1] : [0], id: \.self) { series in
                    let point = samples.last { $0.series == series }
                    HStack(spacing: 3) {
                        Circle().fill(series == 0 ? Theme.mint : Theme.cyan).frame(width: 4, height: 4)
                        if metric == .network || metric == .blockIO {
                            Text(metric == .network ? (series == 0 ? "↓" : "↑") : (series == 0 ? L("读", "R") : L("写", "W")))
                        }
                        Text(point.map { String(format: "%.2f", $0.value) } ?? "—")
                    }
                }
            }
            .font(Theme.mono(8.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                LineMark(x: .value("Time", sample.time), y: .value("Value", sample.value),
                         series: .value("Segment", sample.segment))
                    .foregroundStyle(by: .value("Series", sample.series))
                    .lineStyle(StrokeStyle(lineWidth: 1.2))
                PointMark(x: .value("Time", sample.time), y: .value("Value", sample.value))
                    .foregroundStyle(by: .value("Series", sample.series)).symbolSize(5)
            }
            if let selection {
                RuleMark(x: .value("Time", selection)).foregroundStyle(Theme.tertiary)
            }
        }
        .chartForegroundStyleScale(domain: [0, 1], range: [Theme.mint, Theme.cyan])
        .chartXScale(domain: end.addingTimeInterval(-Double(window))...end)
        .chartYScale(domain: 0...max(1, (samples.map(\.value).max() ?? 1) * 1.1))
        .chartXSelection(value: $selection)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(.system(size: 8)).foregroundStyle(Theme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) {
                AxisGridLine().foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(.system(size: 8)).foregroundStyle(Theme.tertiary)
            }
        }
        .chartLegend(.hidden)
    }
}
