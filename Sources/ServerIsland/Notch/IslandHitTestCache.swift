import AppKit

/// 采样/页面变化时失效；同一界面状态下的高频鼠标事件复用面板范围，不重复遍历任务与卡片。
@MainActor
final class IslandHitTestCache {
    private var rects: [IslandMode: NSRect] = [:]
    func rect(for mode: IslandMode, make: () -> NSRect) -> NSRect {
        if let cached = rects[mode] { return cached }
        let rect = make()
        rects[mode] = rect
        return rect
    }
    func invalidate() { rects.removeAll(keepingCapacity: true) }
}
