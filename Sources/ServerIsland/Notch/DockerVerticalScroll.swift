import AppKit
import SwiftUI

/// 容器列表和指标只允许纵向浏览；按视口扣除细滚动条宽度，阻止子网格的理想宽度撑大文档。
struct DockerVerticalScroll<Content: View>: View {
    @ViewBuilder var content: Content

    static func contentWidth(for width: CGFloat) -> CGFloat {
        max(0, width - IslandThinScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy))
    }

    var body: some View {
        if IslandPreview.active {
            VStack(spacing: 0) { content; Spacer(minLength: 0) }
        } else {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    content
                        .frame(width: Self.contentWidth(for: geometry.size.width), alignment: .leading)
                        .background(DockerVerticalScrollProbe().allowsHitTesting(false))
                }
            }
        }
    }
}

struct DockerVerticalScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.schedule() }

    final class Marker: NSView {
        private var pending = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); schedule() }
        override func layout() { super.layout(); schedule() }

        // 首次 update 可能早于 SwiftUI 挂入 NSScrollView；不能把一次未找到祖先当成登记完成。
        // 后续布局也再次确认方向，覆盖 SwiftUI 初始布局稍晚恢复横轴控件的情况。
        func schedule(attempt: Int = 0) {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard self.window is IslandPanel, let scroll = self.enclosingScrollView else {
                    if attempt < 6 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                            self?.schedule(attempt: attempt + 1)
                        }
                    }
                    return
                }
                IslandScrollbars.markVerticalOnly(scroll)
            }
        }
    }
}
