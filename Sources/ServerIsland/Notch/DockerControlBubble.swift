import SwiftUI

struct DockerControlAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 气泡留在灵动岛内，不另开系统窗口，避免移向确认按钮时触发面板自动收起。
struct DockerControlBubble: View {
    var action: DockerControlAction
    var containerName: String
    var hostName: String
    var containerID: String
    var arrowX: CGFloat
    var onCancel: () -> Void
    var onConfirm: () -> Void

    private var tint: Color { action == .start ? Theme.mint : action == .stop ? Theme.coral : Theme.amber }
    private var bubbleShape: BubbleSilhouette { BubbleSilhouette(arrowX: arrowX) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: 7)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: action == .start ? "play.fill" : action == .stop ? "stop.fill" : "arrow.triangle.2.circlepath")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
                    Text(L("确认", "Confirm ") + action.label)
                        .font(Theme.rounded(12, .semibold)).foregroundStyle(Theme.text)
                    Spacer(minLength: 0)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(containerName).font(Theme.rounded(11, .medium)).foregroundStyle(Theme.text)
                        .lineLimit(2).truncationMode(.middle)
                    Text(hostName + " · " + String(containerID.prefix(12)))
                        .font(Theme.mono(9)).foregroundStyle(Theme.tertiary).lineLimit(1).truncationMode(.middle)
                }
                Text(action == .start ? L("启动此容器。", "Start this container.")
                     : action == .stop ? L("容器停止后，当前服务将不可用。", "The service will be unavailable after the container stops.")
                     : L("重启期间，容器服务会短暂中断。", "The container service will briefly be interrupted during restart."))
                    .font(Theme.rounded(10.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Spacer(minLength: 0)
                    PillButton(title: L("取消", "Cancel"), tint: Theme.secondary, action: onCancel)
                    PillButton(title: L("确认", "Confirm ") + action.label, tint: tint, action: onConfirm)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 黑色岛面缺少背景色差，用浅灰透光层提亮磨砂质感；不降低文字与按钮的不透明度。
        // 箭头与卡片共用一层背景材质，避免接缝；模糊只作用于背后的内容。
        .background {
            bubbleShape.fill(.ultraThinMaterial).opacity(0.78)
                .overlay(bubbleShape.fill(LinearGradient(
                    colors: [.white.opacity(0.15), .white.opacity(0.08)],
                    startPoint: .topLeading, endPoint: .bottomTrailing)))
                .onTapGesture {}
        }
        .overlay(bubbleShape.stroke(Color.white.opacity(0.24), lineWidth: 0.7).allowsHitTesting(false))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
        .transaction { $0.animation = nil }
    }
}

private struct BubbleSilhouette: Shape {
    var arrowX: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 12
        let top = rect.minY + 7
        let tip = min(max(rect.minX + radius + 7, rect.minX + arrowX), rect.maxX - radius - 7)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX + radius, y: top))
            path.addLine(to: CGPoint(x: tip - 7, y: top))
            path.addLine(to: CGPoint(x: tip, y: rect.minY))
            path.addLine(to: CGPoint(x: tip + 7, y: top))
            path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
            path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - radius), control: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
            path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
            path.closeSubpath()
        }
    }
}
