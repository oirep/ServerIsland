import AppKit
import SwiftUI
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let demo: Bool
    private var store: ConfigStore!
    private var engine: MonitorEngine!
    private var island: IslandController!
    private var settings: SettingsWindowController!
    private var statusItem: NSStatusItem!

    init(demo: Bool) {
        self.demo = demo
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        store = ConfigStore(persist: !demo)
        if demo { store.settings = DemoData.settings() }
        engine = MonitorEngine(store: store, demo: demo)
        settings = SettingsWindowController(store: store, engine: engine)
        island = IslandController(engine: engine, store: store) { [weak self] in self?.settings.show() }
        engine.onEvent = { [weak self] e in self?.postNotification(e) }

        setupStatusItem()
        island.show()
        engine.start()

        if store.settings.systemNotifications && !demo {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        // 第一次启动：直接打开设置，引导添加服务器。
        if store.settings.hosts.isEmpty && !demo {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.settings.show() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        store.saveNow()
    }

    // MARK: - 菜单栏图标

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let image = Bundle.main.image(forResource: "menubar") {
                image.isTemplate = true
                image.size = NSSize(width: 18, height: 18)
                button.image = image
            } else {
                button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: "ServerIsland")
            }
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let hosts = engine.orderedHosts
        if hosts.isEmpty {
            menu.addItem(withTitle: L("还没有添加服务器", "No servers yet"), action: nil, keyEquivalent: "")
        }
        for (host, snap) in hosts {
            let status: String
            switch snap.health {
            case .ok: status = L("运行 \(snap.runningCount) · 排队 \(snap.pendingCount)", "\(snap.runningCount) running · \(snap.pendingCount) pending")
            case .needsLogin(let m): status = m
            case .error(let m): status = m
            case .unknown: status = L("连接中…", "Connecting…")
            }
            let dot: String = {
                switch snap.health {
                case .ok: return "🟢"
                case .needsLogin: return "🟡"
                case .error: return "🔴"
                case .unknown: return "⚪️"
                }
            }()
            let item = NSMenuItem(title: "\(dot)  \(host.displayName) — \(status)", action: nil, keyEquivalent: "")
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(item(L("立即刷新", "Refresh Now"), #selector(refresh), "r"))
        menu.addItem(item(L("设置…", "Settings…"), #selector(openSettings), ","))
        menu.addItem(.separator())
        menu.addItem(item(L("退出 ServerIsland", "Quit ServerIsland"), #selector(quit), "q"))
    }

    private func item(_ title: String, _ action: Selector, _ key: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    @objc private func refresh() { engine.refreshAll() }
    @objc private func openSettings() { settings.show() }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: - 系统通知

    private func postNotification(_ event: IslandEvent) {
        guard store.settings.systemNotifications, !demo, event.kind != .started else { return }
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.subtitle = event.hostName
        content.body = event.subtitle
        // 已经播放了自己的提示音时，系统通知就不再响。
        content.sound = store.settings.soundEnabled ? nil : (event.kind == .failed ? .defaultCritical : .default)
        let req = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
