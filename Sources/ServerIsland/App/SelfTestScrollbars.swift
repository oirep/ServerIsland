import AppKit
import SwiftUI

/// 只建离屏控件，验证原生滚动连接不被替换破坏，不开窗口或渲染截图。
@MainActor
enum SelfTestScrollbars {
    static func run(_ check: (Bool, String) -> Void) {
        let dockerViewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        dockerViewport.borderType = .noBorder
        dockerViewport.hasVerticalScroller = true; dockerViewport.hasHorizontalScroller = true
        dockerViewport.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        IslandScrollbars.markVerticalOnly(dockerViewport)
        check(!dockerViewport.hasHorizontalScroller && dockerViewport.horizontalScrollElasticity == .none,
              "Docker 滚动方向：列表/指标仅纵向，不显示横向滚动条或横向回弹")
        dockerViewport.hasHorizontalScroller = true
        IslandScrollbars.apply(in: dockerViewport)
        check(!dockerViewport.hasHorizontalScroller, "Docker 滚动方向：重新布局和细滚动条扫描不会恢复横向条")
        let mountingPanel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        mountingPanel.isReleasedWhenClosed = false
        let initialProbe = DockerVerticalScrollProbe.Marker(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        mountingPanel.contentView?.addSubview(initialProbe)
        initialProbe.schedule()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        let mountedViewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        mountedViewport.hasVerticalScroller = true
        mountedViewport.hasHorizontalScroller = true
        let mountedDocument = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 400))
        mountedViewport.documentView = mountedDocument
        mountingPanel.contentView?.addSubview(mountedViewport)
        mountedDocument.addSubview(initialProbe)
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(!mountedViewport.hasHorizontalScroller && mountedViewport.horizontalScrollElasticity == .none,
              "Docker 首次挂载：探针早于滚动祖先出现也能登记纵向，无需切换视图")
        mountedViewport.hasHorizontalScroller = true
        initialProbe.layout()
        RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        check(!mountedViewport.hasHorizontalScroller,
              "Docker 首次挂载：SwiftUI 后续布局恢复横轴时自动纠正")
        mountingPanel.close()
        let logViewport = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        logViewport.hasHorizontalScroller = true
        IslandScrollbars.apply(in: logViewport)
        check(logViewport.hasHorizontalScroller, "Docker 滚动方向：未登记的日志区保留横向滚动")
        dockerViewport.tile()
        let fitted = DockerVerticalScroll<EmptyView>.contentWidth(for: dockerViewport.frame.width)
        check(fitted <= dockerViewport.contentSize.width && fitted > 0
              && DockerVerticalScroll<EmptyView>.contentWidth(for: 0) == 0,
              "Docker 内容宽度：扣除实际细滚动条占位，不超过原生视口，零尺寸不产生负宽度")
        let hitCache = IslandHitTestCache()
        var geometryBuilds = 0
        for _ in 0..<5000 {
            _ = hitCache.rect(for: .expanded) { geometryBuilds += 1; return NSRect(x: 0, y: 0, width: 600, height: 300) }
        }
        check(geometryBuilds == 1, "界面命中检测：5000 次鼠标查询只计算一次卡片范围")
        hitCache.invalidate()
        let resized = hitCache.rect(for: .expanded) { geometryBuilds += 1; return NSRect(x: 0, y: 0, width: 600, height: 400) }
        check(geometryBuilds == 2 && resized.height == 400, "界面命中检测：页面/数据改变后可重新计算范围")

        let retained = IslandViewModel()
        let home = IslandViewModel()
        home.showIdle = true
        home.pinned = true
        home.retainCollapsedContent(seconds: 30)
        check(home.page == .list && home.contentRetainedUntil == nil && !home.showIdle && !home.pinned,
              "可视内容保留：首页直接清理，不进入保留计时")
        let retentionHost = UUID()
        let retentionNow = Date(timeIntervalSince1970: 1000)
        retained.page = .docker(host: retentionHost, container: "demo-container")
        retained.retainCollapsedContent(seconds: 0, now: retentionNow)
        check(retained.page == .list && retained.contentRetainedUntil == nil,
              "可视内容保留：默认立即重置首页")
        retained.page = .docker(host: retentionHost, container: "demo-container")
        retained.retainCollapsedContent(seconds: 3, now: retentionNow)
        retained.expireRetainedContent(now: retentionNow.addingTimeInterval(2.99))
        check(retained.page == .docker(host: retentionHost, container: "demo-container") && retained.contentRetainedUntil != nil,
              "可视内容保留：期限内仍保留原容器详情")
        retained.hovering = true
        retained.resumeRetainedContent(now: retentionNow.addingTimeInterval(2))
        check(retained.page == .docker(host: retentionHost, container: "demo-container") && retained.contentRetainedUntil == nil,
              "可视内容保留：及时返回取消本轮倒计时，不改变页面")
        retained.hovering = false
        retained.retainCollapsedContent(seconds: 5, now: retentionNow.addingTimeInterval(2))
        retained.expireRetainedContent(now: retentionNow.addingTimeInterval(3))
        check(retained.contentRetainedUntil == retentionNow.addingTimeInterval(7) && retained.page != .list,
              "可视内容保留：再次收起从新的收起时刻重新计时")
        retained.returnPage = .jobs
        retained.expireRetainedContent(now: retentionNow.addingTimeInterval(7))
        check(retained.page == .list && retained.returnPage == nil && retained.contentRetainedUntil == nil,
              "可视内容保留：到期自动回首页并清理详情返回路径")
        retained.page = .docker(host: retentionHost, container: nil)
        retained.retainCollapsedContent(seconds: 10, now: retentionNow)
        retained.resumeRetainedContent(now: retentionNow.addingTimeInterval(11))
        check(retained.page == .list, "可视内容保留：倒计时回调延迟也不会恢复已过期内容")

        let tooltipWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                                     styleMask: .titled, backing: .buffered, defer: false)
        tooltipWindow.isReleasedWhenClosed = false
        let tooltip = IslandTooltipTarget(frame: NSRect(x: 0, y: 0, width: 120, height: 20))
        tooltipWindow.contentView?.addSubview(tooltip)
        tooltip.updateText("CPU 1%")
        for value in 2...30 { tooltip.updateText("CPU \(value)%") }
        check(tooltip.registrationCount == 1
              && tooltip.view(tooltip, stringForToolTip: 0, point: .zero, userData: nil) == "CPU 30%",
              "界面 tips：连续数据更新只登记一次提示区域，并读取最新文字")
        check(tooltip.hitTest(NSPoint(x: 5, y: 5)) == nil, "界面 tips：提示视图不截获按钮点击或悬停目标")
        tooltip.setFrameSize(NSSize(width: 160, height: 20))
        check(tooltip.registrationCount == 2, "界面 tips：控件实际变宽时更新有效提示区域")
        tooltip.updateText(""); tooltip.updateText("恢复提示")
        check(tooltip.registrationCount == 3, "界面 tips：空提示隐藏后可恢复，不残留旧区域")
        tooltipWindow.close()

        let scanProbe = IslandScanProbe(frame: .zero)
        scanProbe.inspections = 0
        for _ in 0..<50 { IslandScrollbars.schedule(in: scanProbe) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(scanProbe.inspections == 1, "界面布局扫描：同一批 50 次请求合并为一次遍历")
        for _ in 0..<50 { IslandScrollbars.schedule(in: scanProbe) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        check(scanProbe.inspections == 2, "界面布局扫描：后续请求限频执行，仍处理新控件")
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

private final class IslandScanProbe: NSView {
    var inspections = 0
    override var subviews: [NSView] {
        get { inspections += 1; return super.subviews }
        set { super.subviews = newValue }
    }
}
