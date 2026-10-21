import AppKit
import SwiftUI

/// 使用细版常显样式，避免覆盖式滚动条淡出后找不到滑块；交互仍交给 AppKit。
final class IslandThinScroller: NSScroller {
    static let thickness: CGFloat = 4
    override class var isCompatibleWithOverlayScrollers: Bool { false }

    override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { 8 }

    static func visibleKnob(in rect: NSRect, vertical: Bool) -> NSRect {
        if vertical {
            return NSRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
        }
        return NSRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        guard !knob.isEmpty else { return }
        let visible = Self.visibleKnob(in: knob, vertical: bounds.height >= bounds.width)
        NSColor.white.withAlphaComponent(0.72).setFill()
        NSBezierPath(roundedRect: visible, xRadius: Self.thickness / 2, yRadius: Self.thickness / 2).fill()
    }

    override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {
        guard !slotRect.isEmpty else { return }
        let track = Self.visibleKnob(in: slotRect, vertical: bounds.height >= bounds.width)
        NSColor.white.withAlphaComponent(0.06).setFill()
        NSBezierPath(roundedRect: track, xRadius: Self.thickness / 2, yRadius: Self.thickness / 2).fill()
    }
}

@MainActor
enum IslandScrollbars {
    private final class ScanTicket {
        var pending = false
        var lastScan: TimeInterval = 0
    }
    private static let tickets = NSMapTable<NSView, ScanTicket>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static let verticalOnly = NSHashTable<NSScrollView>.weakObjects()

    /// SwiftUI 的纵向滚动区在 legacy 样式下也可能保留横轴控件；仅约束明确登记的 Docker 视口。
    static func markVerticalOnly(_ scroll: NSScrollView) {
        let first = !verticalOnly.contains(scroll)
        verticalOnly.add(scroll)
        if first { apply(in: scroll) }
        if scroll.hasHorizontalScroller { scroll.hasHorizontalScroller = false }
        scroll.horizontalScrollElasticity = .none
        if scroll.contentView.bounds.minX != 0 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.contentView.bounds.minY))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    /// 宿主 layout 与 SwiftUI probe 共用调度；高频悬停只触发合并扫描，避免每次布局递归遍历整棵树。
    static func schedule(in root: NSView) {
        let ticket: ScanTicket
        if let existing = tickets.object(forKey: root) { ticket = existing }
        else { ticket = ScanTicket(); tickets.setObject(ticket, forKey: root) }
        guard !ticket.pending else { return }
        ticket.pending = true
        let delay = max(0, 0.1 - (ProcessInfo.processInfo.systemUptime - ticket.lastScan))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak root, weak ticket] in
            guard let root, let ticket else { return }
            ticket.pending = false
            ticket.lastScan = ProcessInfo.processInfo.systemUptime
            apply(in: root)
        }
    }

    /// 只扫描灵动岛面板的子树，涵盖列表、详情、横向日志和嵌套控件，不改变其它窗口。
    static func apply(in root: NSView) {
        if let scroll = root as? NSScrollView {
            let hadVertical = scroll.hasVerticalScroller
            let hadHorizontal = !verticalOnly.contains(scroll) && scroll.hasHorizontalScroller
            if verticalOnly.contains(scroll) { scroll.horizontalScrollElasticity = .none }
            // legacy 在溢出时持续绘制；autohidesScrollers 只负责内容无需滚动时隐藏。
            if scroll.scrollerStyle != .legacy { scroll.scrollerStyle = .legacy }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if let old = scroll.verticalScroller, !(old is IslandThinScroller) {
                scroll.verticalScroller = replacement(for: old)
            }
            if let old = scroll.horizontalScroller, !(old is IslandThinScroller) {
                scroll.horizontalScroller = replacement(for: old)
            }
            if scroll.hasVerticalScroller != hadVertical { scroll.hasVerticalScroller = hadVertical }
            if scroll.hasHorizontalScroller != hadHorizontal { scroll.hasHorizontalScroller = hadHorizontal }
        }
        for child in root.subviews { apply(in: child) }
    }

    private static func replacement(for old: NSScroller) -> IslandThinScroller {
        let scroller = IslandThinScroller(frame: old.frame)
        scroller.controlSize = old.controlSize
        scroller.scrollerStyle = .legacy
        scroller.knobStyle = .light
        scroller.target = old.target
        scroller.action = old.action
        scroller.isEnabled = old.isEnabled
        scroller.isContinuous = old.isContinuous
        scroller.doubleValue = old.doubleValue
        scroller.knobProportion = old.knobProportion
        scroller.autoresizingMask = old.autoresizingMask
        return scroller
    }
}

/// SwiftUI 换页后补一次扫描，原生宿主 layout 则覆盖异步出现的滚动内容。
struct IslandScrollbarProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.scheduleUpdate() }

    final class Marker: NSView {
        private var pending = false
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); scheduleUpdate() }
        func scheduleUpdate() {
            guard !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                guard self.window is IslandPanel, let root = self.window?.contentView else { return }
                IslandScrollbars.schedule(in: root)
            }
        }
    }
}
