import AppKit
import SwiftUI

extension View {
    /// 动态数值只更新提示文字，不重新登记悬停区域，避免刷新反复打断系统提示计时。
    func islandHelp(_ text: String) -> some View {
        background(IslandTooltip(text: text).allowsHitTesting(false))
    }
}

private struct IslandTooltip: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> IslandTooltipTarget { IslandTooltipTarget() }
    func updateNSView(_ view: IslandTooltipTarget, context: Context) { view.updateText(text) }
    static func dismantleNSView(_ view: IslandTooltipTarget, coordinator: ()) { view.unregister() }
}

final class IslandTooltipTarget: NSView, NSViewToolTipOwner {
    private var text = ""
    private var tooltipTag: Int?
    private var registeredRect = NSRect.zero
    private(set) var registrationCount = 0

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func updateText(_ value: String) {
        text = value
        updateRegion()
    }

    override func layout() {
        super.layout()
        updateRegion()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateRegion()
    }

    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        updateRegion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        unregister()
        updateRegion()
    }

    private func updateRegion() {
        guard window != nil, !text.isEmpty, !bounds.isEmpty else { unregister(); return }
        guard tooltipTag == nil || registeredRect != bounds else { return }
        unregister()
        registeredRect = bounds
        tooltipTag = addToolTip(bounds, owner: self, userData: nil)
        registrationCount += 1
    }

    func unregister() {
        if let tooltipTag { removeToolTip(tooltipTag) }
        tooltipTag = nil
    }

    func view(_ view: NSView, stringForToolTip tag: Int, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
        text
    }
}
