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

private struct DockerVerticalScrollProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.schedule() }

    final class Marker: NSView {
        private var pending = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); schedule() }
        func schedule() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard self.window is IslandPanel, let scroll = self.enclosingScrollView else { return }
                IslandScrollbars.markVerticalOnly(scroll)
            }
        }
    }
}
