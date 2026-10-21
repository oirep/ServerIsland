import AppKit
import SwiftUI

/// 日志两轴独立定位：仅在原本位于底部时跟随追加，横向位置始终由用户控制。
struct DockerLogScrollView: NSViewRepresentable {
    var text: AttributedString
    var follow: Bool
    var matches = DockerLogMatches()
    var selectedMatch = 0
    var jumpToken: UUID?

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        view.isEditable = false
        view.isSelectable = true
        view.drawsBackground = false
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.textContainer?.lineFragmentPadding = 0
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = true
        view.minSize = .zero
        view.maxSize = NSSize(width: 10_000_000, height: 10_000_000)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = view.maxSize
        scroll.documentView = view
        return scroll
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView else { return }
        let textChanged = context.coordinator.previous != text
        if textChanged {
            let old = view.string
            let origin = scroll.contentView.bounds.origin
            let atBottom = view.frame.height - scroll.contentView.bounds.maxY <= 3
            let first = context.coordinator.previous == nil
            context.coordinator.previous = text
            let selection = view.selectedRange()
            view.textStorage?.setAttributedString(DockerLogText.native(text))
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            view.setFrameSize(NSSize(width: max(scroll.contentSize.width, ceil(used.maxX) + 20),
                                     height: max(scroll.contentSize.height, ceil(used.maxY) + 20)))
            view.setSelectedRange(NSRange(location: min(selection.location, view.string.utf16.count), length: 0))
            let removed = Self.removedLines(old: old, new: view.string)
            let lineHeight = manager.defaultLineHeight(for: .monospacedSystemFont(ofSize: 10.5, weight: .regular))
            let target = Self.position(origin: origin, viewport: scroll.contentView.bounds.size,
                                       document: view.frame.size, followBottom: first || (follow && atBottom),
                                       removedHeight: CGFloat(removed) * lineHeight)
            scroll.contentView.scroll(to: target)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        if textChanged || context.coordinator.matches != matches || context.coordinator.selectedMatch != selectedMatch {
            context.coordinator.matches = matches
            context.coordinator.selectedMatch = selectedMatch
            Self.highlight(view, matches: matches, selected: selectedMatch)
        }
        if let jumpToken, context.coordinator.jumpToken != jumpToken {
            context.coordinator.jumpToken = jumpToken
            if matches.ranges.indices.contains(selectedMatch) {
                let range = matches.ranges[selectedMatch]
                if NSMaxRange(range) <= view.string.utf16.count { view.scrollRangeToVisible(range) }
            }
        }
    }

    /// 临时背景高亮不修改 ANSI 前景色或用户的文本选择。
    static func highlight(_ view: NSTextView, matches: DockerLogMatches, selected: Int) {
        let count = view.string.utf16.count
        view.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: count))
        for (index, range) in matches.ranges.enumerated() where NSMaxRange(range) <= count {
            view.layoutManager?.addTemporaryAttribute(.backgroundColor,
                value: index == selected ? NSColor.systemOrange.withAlphaComponent(0.5) : NSColor.systemYellow.withAlphaComponent(0.22),
                forCharacterRange: range)
        }
    }

    /// tail 窗口淘汰旧行时抵消其高度，避免正在阅读的保留行随新日志漂移。
    static func removedLines(old: String, new: String) -> Int {
        guard !old.isEmpty, !new.isEmpty, !new.hasPrefix(old) else { return 0 }
        let head = new.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).joined(separator: "\n")
        guard !head.isEmpty, let match = old.range(of: head),
              match.lowerBound == old.startIndex || old[old.index(before: match.lowerBound)] == "\n" else { return 0 }
        return old[..<match.lowerBound].reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
    }

    static func position(origin: NSPoint, viewport: NSSize, document: NSSize,
                         followBottom: Bool, removedHeight: CGFloat) -> NSPoint {
        let maxX = max(0, document.width - viewport.width)
        let maxY = max(0, document.height - viewport.height)
        return NSPoint(x: min(maxX, max(0, origin.x)),
                       y: followBottom ? maxY : min(maxY, max(0, origin.y - removedHeight)))
    }

    final class Coordinator {
        var previous: AttributedString?
        var matches = DockerLogMatches()
        var selectedMatch = 0
        var jumpToken: UUID?
    }
}
