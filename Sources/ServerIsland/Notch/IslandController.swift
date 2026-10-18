import AppKit
import Combine
import SwiftUI

/// 第一次点击就能触发按钮（面板不会成为 key window）。
final class IslandHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class IslandPanel: NSPanel {
    /// 只有在需要输入文字（任务列表的搜索框）时才允许成为 key window，平时不抢键盘焦点。
    var allowsKey: () -> Bool = { false }
    override var canBecomeKey: Bool { allowsKey() }
    override var canBecomeMain: Bool { false }
}

/// 管理刘海面板：定位、悬停展开 / 收起、屏幕变化。
@MainActor
final class IslandController {
    let vm = IslandViewModel()
    private let engine: MonitorEngine
    private let store: ConfigStore
    private var panel: IslandPanel?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var expandWork: DispatchWorkItem?
    private var collapseWork: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []
    private var menuTracking = false

    init(engine: MonitorEngine, store: ConfigStore, openSettings: @escaping () -> Void) {
        self.engine = engine
        self.store = store
        vm.onUnpin = { [weak self] in self?.unpinned() }
        vm.openSettings = { [weak self] in
            self?.setHovering(false)
            openSettings()
        }
    }

    func show() {
        let panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar + 8   // 盖过菜单栏
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true
        panel.contentView = IslandHostingView(rootView: IslandRootView(vm: vm, engine: engine, store: store))
        panel.allowsKey = { [weak self] in
            if case .jobs = self?.vm.page { return true }
            return false
        }
        self.panel = panel
        reposition()
        panel.orderFrontRegardless()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouse() }
        } as Any)
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .mouseExited]) { [weak self] e in
            self?.handleMouse()
            return e
        } as Any)

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        })
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.panel?.orderFrontRegardless() }
        })
        // 菜单（轮询间隔等）打开期间，鼠标会移到形状外，此时不要收起面板。
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.menuTracking = true; self?.collapseWork?.cancel(); self?.collapseWork = nil }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.menuTracking = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self?.handleMouse() }
            }
        })
        // 设置里换了显示的屏幕
        store.$settings.map(\.islandScreen).removeDuplicates().dropFirst().receive(on: DispatchQueue.main).sink { [weak self] v in
            MainActor.assumeIsolated {
                NSScreen.islandPreference = v
                self?.reposition()
            }
        }.store(in: &cancellables)
        // 事件提示出现时，刘海区域变大，也要能悬停展开。
        engine.$currentEvent.sink { [weak self] _ in
            DispatchQueue.main.async { self?.handleMouse() }
        }.store(in: &cancellables)
    }

    /// 取消固定后，如果鼠标已经不在面板上就收起。
    func unpinned() { handleMouse() }

    func reposition() {
        guard let panel else { return }
        let g = NotchGeometry.current()
        vm.geometry = g
        let size = IslandLayout.panelSize(g)
        panel.setFrame(NSRect(x: g.midX - size.width / 2, y: g.screenFrame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
    }

    /// 当前形状在屏幕上的矩形。
    private func shapeRect(for mode: IslandMode) -> NSRect {
        let g = vm.geometry
        let spec = IslandLayout.spec(mode: mode, geometry: g, contentHeight: vm.contentHeight(engine.orderedHosts, fold: store.settings.foldIdleHosts))
        return NSRect(x: g.midX - spec.size.width / 2, y: g.screenFrame.maxY - spec.size.height,
                      width: spec.size.width, height: spec.size.height)
    }

    private func handleMouse() {
        let p = NSEvent.mouseLocation
        if vm.hovering {
            let shape = shapeRect(for: .expanded)
            // 面板比形状大：只有鼠标在形状里时才接收点击，形状外的透明区域让点击穿透到下面的窗口。
            panel?.ignoresMouseEvents = !shape.insetBy(dx: -2, dy: -2).contains(p)
            let rect = shape.insetBy(dx: -12, dy: -12)
            if rect.contains(p) || vm.pinned || menuTracking {
                collapseWork?.cancel(); collapseWork = nil
            } else if collapseWork == nil {
                let work = DispatchWorkItem { [weak self] in self?.setHovering(false) }
                collapseWork = work
                // 在详情等二级页面里多给一点余量，避免鼠标稍微滑出就丢失页面。
                DispatchQueue.main.asyncAfter(deadline: .now() + (vm.page == .list ? 0.25 : 0.7), execute: work)
            }
        } else {
            let mode = IslandLayout.mode(hovering: false, engine: engine, style: store.settings.collapsedStyle)
            var rect = shapeRect(for: mode)
            // 没有刘海或隐藏状态时，给一个合理的最小触发区域。
            if rect.width < 160 {
                rect = rect.insetBy(dx: -(160 - rect.width) / 2, dy: 0)
            }
            rect = rect.insetBy(dx: -2, dy: -2)
            if rect.contains(p) {
                if expandWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.expandWork = nil
                        if rect.contains(NSEvent.mouseLocation) { self.setHovering(true) }
                    }
                    expandWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.14, execute: work)
                }
            } else {
                expandWork?.cancel(); expandWork = nil
            }
        }
    }

    private func setHovering(_ on: Bool) {
        collapseWork?.cancel(); collapseWork = nil
        expandWork?.cancel(); expandWork = nil
        guard vm.hovering != on else { return }
        vm.hovering = on
        if !on { vm.page = .list; vm.pinned = false; vm.showIdle = false }
        panel?.ignoresMouseEvents = !on
        if on {
            engine.dismissEvent()
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }
}
