import AppKit

/// 只建离屏控件，验证原生滚动连接不被替换破坏，不开窗口或渲染截图。
@MainActor
enum SelfTestScrollbars {
    static func run(_ check: (Bool, String) -> Void) {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 160, height: 100))
        let document = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        scroll.documentView = document
        scroll.hasVerticalScroller = true; scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = false
        root.addSubview(scroll)
        let target = scroll.verticalScroller?.target
        let action = scroll.verticalScroller?.action
        let outside = NSScrollView(frame: .zero)
        outside.hasVerticalScroller = true
        IslandScrollbars.apply(in: root)
        check(scroll.verticalScroller is IslandThinScroller && scroll.horizontalScroller is IslandThinScroller,
              "灵动岛滚动条：同一宿主内横向与纵向均采用细样式")
        check(scroll.verticalScroller?.target === target && scroll.verticalScroller?.action == action
              && scroll.documentView === document && scroll.autohidesScrollers && scroll.scrollerStyle == .legacy,
              "灵动岛滚动条：保留原生事件和内容，溢出时常显，无需滚动时隐藏")
        scroll.tile()
        scroll.reflectScrolledClipView(scroll.contentView)
        scroll.verticalScroller?.checkSpaceForParts()
        scroll.horizontalScroller?.checkSpaceForParts()
        check(scroll.verticalScroller.map { !$0.rect(for: .knob).isEmpty && $0.knobProportion < 1 } == true
              && scroll.horizontalScroller.map { !$0.rect(for: .knob).isEmpty && $0.knobProportion < 1 } == true,
              "灵动岛滚动条：溢出内容的横纵原生滑块均有有效绘制区域")
        scroll.contentView.scroll(to: NSPoint(x: 40, y: 75))
        scroll.reflectScrolledClipView(scroll.contentView)
        let scroller = scroll.verticalScroller
        IslandScrollbars.apply(in: root)
        check(scroll.contentView.bounds.origin == NSPoint(x: 40, y: 75) && scroll.verticalScroller === scroller,
              "灵动岛滚动条：重复刷新不重建控件或重置横纵滚动位置")
        check(!(outside.verticalScroller is IslandThinScroller), "灵动岛滚动条：不修改面板外的其它窗口控件")
        let hidden = NSScrollView(frame: .zero)
        hidden.hasVerticalScroller = false; hidden.hasHorizontalScroller = false
        root.addSubview(hidden)
        IslandScrollbars.apply(in: root)
        check(!hidden.hasVerticalScroller && !hidden.hasHorizontalScroller,
              "灵动岛滚动条：不额外显示原本关闭的滚动条")
        let vertical = IslandThinScroller.visibleKnob(in: NSRect(x: 0, y: 20, width: 14, height: 80), vertical: true)
        let horizontal = IslandThinScroller.visibleKnob(in: NSRect(x: 10, y: 0, width: 80, height: 14), vertical: false)
        check(vertical.width == 4 && horizontal.height == 4 && vertical.height == 80 && horizontal.width == 80,
              "灵动岛滚动条：两种方向均为 4pt，保持原有滑块长度")
    }
}
