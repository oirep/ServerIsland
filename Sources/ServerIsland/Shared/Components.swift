import AppKit
import SwiftUI

/// 带柔光的状态圆点。
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: size * 0.6)
    }
}

/// 细长进度条。fraction 为 nil 时只显示轨道（不做常驻动画以节省资源）。
struct SlimBar: View {
    var fraction: Double?
    var fill: AnyShapeStyle = AnyShapeStyle(Theme.progress)
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let f = fraction {
                    Capsule()
                        .fill(fill)
                        .frame(width: max(height, geo.size.width * f))
                        .animation(.easeOut(duration: 0.6), value: f)
                }
            }
        }
        .frame(height: height)
    }
}

/// 进度环（收起状态右翼用）。
struct ProgressRing: View {
    var fraction: Double
    var lineWidth: CGFloat = 2.6
    var gradient: Bool = true

    var body: some View {
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, fraction))
                .stroke(gradient ? AnyShapeStyle(AngularGradient(colors: [Theme.mint, Theme.cyan, Theme.mint],
                                                                 center: .center)) : AnyShapeStyle(Theme.mint),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.6), value: fraction)
        }
    }
}

/// "CPU 34% ▬▬▬" 样式的小指标。
struct MetricChip: View {
    var label: String
    var fraction: Double
    var valueText: String
    var help: String = ""
    var showsFractionOnClick = false
    @State private var fractionShown = false

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.rounded(9.5, .semibold))
                .foregroundStyle(Theme.tertiary)
            SlimBar(fraction: fraction, fill: AnyShapeStyle(Theme.load(fraction)), height: 4)
                .frame(width: 44)
            // 预留两种数值的宽度，点击切换时不挤动其它指标和 Action。
            ZStack(alignment: .leading) {
                Text(valueText).hidden()
                if showsFractionOnClick { Text("100.0%").hidden() }
                Text(showsFractionOnClick && fractionShown
                     ? String(format: "%.1f%%", fraction * 100) : valueText)
            }
                .font(Theme.rounded(10.5, .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
                .frame(minWidth: 28, alignment: .leading)
        }
        .help(showsFractionOnClick ? "" : help)
        .contentShape(Rectangle())
        .onTapGesture { if showsFractionOnClick { fractionShown.toggle() } }
    }
}

/// 每张 GPU 一个小方块，填充高度 = 利用率，颜色随显存占用变化。
struct GPUCells: View {
    var gpus: [GPUStat]

    private func gpuHelp(_ g: GPUStat) -> String {
        let util = L("利用率", "util") + " \(Int(g.utilization))%"
        let mem = L("显存", "VRAM") + " \(Int(g.memoryUsedMB / 1024))/\(Int(g.memoryTotalMB / 1024)) GB"
        let temp = g.temperature.map { " · \(Int($0))°C" } ?? ""
        return "GPU \(g.index) · \(g.name)\n" + util + " · " + mem + temp
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("GPU")
                .font(Theme.rounded(9.5, .semibold))
                .foregroundStyle(Theme.tertiary)
            HStack(spacing: 3) {
                ForEach(gpus.prefix(16)) { g in
                    let u = g.utilization / 100
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2.5).fill(Theme.track)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(LinearGradient(colors: [Theme.cyan, Theme.mint], startPoint: .bottom, endPoint: .top))
                            .frame(height: u > 0.01 ? max(2, 14 * u) : 0)
                        // 显存快满时在顶部加一条琥珀色提示线。
                        if g.memoryFraction > 0.9 {
                            VStack { Capsule().fill(Theme.amber).frame(height: 2); Spacer(minLength: 0) }
                        }
                    }
                    .frame(width: gpus.count > 8 ? 6 : 8, height: 14)
                    .help(gpuHelp(g))
                }
            }
            let busy = gpus.filter { $0.utilization > 5 || $0.memoryFraction > 0.1 }.count
            Text(L("\(gpus.count - busy)/\(gpus.count) 空闲", "\(gpus.count - busy)/\(gpus.count) idle"))
                .font(Theme.rounded(10, .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
    }
}

struct KindBadge: View {
    var kind: HostKind

    var body: some View {
        Text(kind.badge)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(kind.isScheduler ? Theme.violet : Theme.cyan)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Capsule().fill((kind.isScheduler ? Theme.violet : Theme.cyan).opacity(0.14)))
    }
}

/// 单台服务器的运行 / 排队数量（数组按元素算），为 0 的那一项不显示。
struct JobCountChips: View {
    var running: Int
    var pending: Int
    var dimmed = false

    var body: some View {
        HStack(spacing: 7) {
            if running > 0 { chip("bolt.fill", running, Theme.mint) }
            if pending > 0 { chip("hourglass", pending, Theme.amber) }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.white.opacity(0.06)))
        .opacity(dimmed ? 0.5 : 1)
        .fixedSize()
        .help(L("这台服务器：\(running) 个运行中 · \(pending) 个排队中\n数组作业按元素计数，所以可能比列表的行数多",
                "This server: \(running) running · \(pending) pending\nArray jobs count each element, so this can exceed the rows shown"))
    }

    private func chip(_ icon: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: icon).font(.system(size: 7.5, weight: .bold))
            Text("\(value)").font(Theme.rounded(10, .semibold).monospacedDigit())
        }
        .foregroundStyle(color)
    }
}

/// 应用标志的简化版：一座"灵动岛"，左侧亮灯、右侧进度。
struct LogoGlyph: View {
    var size: CGFloat = 14

    var body: some View {
        ZStack {
            Capsule()
                .fill(LinearGradient(colors: [Color(white: 0.20), Color(white: 0.07)], startPoint: .top, endPoint: .bottom))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6))
            HStack(spacing: size * 0.14) {
                Circle().fill(Theme.mint).frame(width: size * 0.26, height: size * 0.26)
                    .shadow(color: Theme.mint, radius: size * 0.12)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.18))
                    Capsule().fill(Theme.progress).frame(width: size * 0.44)
                }
                .frame(width: size * 0.66, height: size * 0.14)
            }
        }
        .frame(width: size * 1.6, height: size * 0.72)
    }
}

/// 小号圆形图标按钮（刷新 / 设置）。
struct IslandIconButton: View {
    var systemName: String
    var help: String
    var spinning = false
    var active = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Theme.mint : (hovering ? Theme.text : Theme.secondary))
                .rotationEffect(.degrees(spinning ? 360 : 0))
                .animation(spinning ? .linear(duration: 0.9).repeatForever(autoreverses: false) : .default, value: spinning)
                .frame(width: 24, height: 24)
                .background(Circle().fill(active ? Theme.mint.opacity(0.18) : Color.white.opacity(hovering ? 0.14 : 0.07)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        // 详情持续刷新时保留原生提示区域，避免反复重置系统悬停计时。
        .islandHelp(help)
    }
}

/// GPU 数量少（1–2 张）时的详细指标：利用率条 + 显存 + 温度。
struct GPUDetailChip: View {
    var gpu: GPUStat
    var showIndex: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(showIndex ? "GPU\(gpu.index)" : "GPU")
                .font(Theme.rounded(9.5, .semibold))
                .foregroundStyle(Theme.tertiary)
            SlimBar(fraction: gpu.utilization / 100,
                    fill: AnyShapeStyle(LinearGradient(colors: [Theme.cyan, Theme.mint], startPoint: .leading, endPoint: .trailing)),
                    height: 4)
                .frame(width: 44)
            Text("\(Int(gpu.utilization))%")
                .font(Theme.rounded(10.5, .medium).monospacedDigit())
                .foregroundStyle(Theme.secondary)
            Text(String(format: "%.1f/%.0fG", gpu.memoryUsedMB / 1024, gpu.memoryTotalMB / 1024))
                .font(Theme.rounded(10.5, .medium).monospacedDigit())
                .foregroundStyle(gpu.memoryFraction > 0.9 ? Theme.amber : Theme.secondary)
            if let t = gpu.temperature {
                Text("\(Int(t))°")
                    .font(Theme.rounded(10.5, .medium).monospacedDigit())
                    .foregroundStyle(t >= 80 ? Theme.coral : Theme.tertiary)
            }
        }
        .help(GPUStat.shortName(gpu.name))
    }
}

extension GPUStat {
    /// "NVIDIA GeForce RTX 5090 D v2" -> "RTX 5090 D v2"
    static func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "NVIDIA ", with: "").replacingOccurrences(of: "GeForce ", with: "")
    }
}

/// 复制按钮：点击后短暂显示对勾。
struct CopyButton: View {
    var value: String
    var help: String
    var label: String? = nil
    @State private var copied = false
    @State private var hovering = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 9.5, weight: .semibold))
                if let label { Text(copied ? L("已复制", "Copied") : label).font(Theme.rounded(10, .medium)) }
            }
            .foregroundStyle(copied ? Theme.mint : (hovering ? Theme.text : Theme.tertiary))
            .padding(.horizontal, label == nil ? 0 : 7)
            .frame(minWidth: 20, minHeight: 20)
            .background(Capsule().fill(Color.white.opacity(hovering ? 0.10 : (label == nil ? 0 : 0.05))))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
