import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: ConfigStore
    private let engine: MonitorEngine

    init(store: ConfigStore, engine: MonitorEngine) {
        self.store = store
        self.engine = engine
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "ServerIsland"
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.minSize = NSSize(width: 760, height: 520)
            w.contentView = NSHostingView(rootView: SettingsView(store: store, engine: engine))
            w.center()
            window = w
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
                MainActor.assumeIsolated { _ = NSApp.setActivationPolicy(.accessory) }
            }
        }
        // 菜单栏 App 打开窗口时需要临时激活。
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

enum SettingsPage: Hashable {
    case general
    case rules
    case host(UUID)
}

struct SettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: MonitorEngine
    @State private var selection: SettingsPage? = .general
    @State private var showingAdd = false

    init(store: ConfigStore, engine: MonitorEngine, initial: SettingsPage = .general) {
        self.store = store
        self.engine = engine
        _selection = State(initialValue: initial)
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    SidebarRow(title: L("通用", "General"), subtitle: L("轮询、提醒、提示音", "Refresh, alerts, sounds"),
                               symbol: "gearshape.fill", tint: .gray)
                        .tag(SettingsPage.general)
                    SidebarRow(title: L("进度识别", "Progress Detection"),
                               subtitle: store.settings.progressRules.isEmpty ? L("内置软件、自定义规则", "Built-in apps, custom rules")
                                   : L("\(store.settings.progressRules.count) 条自定义规则", "\(store.settings.progressRules.count) custom rules"),
                               symbol: "wand.and.stars", tint: .indigo)
                        .tag(SettingsPage.rules)
                }
                Section(L("服务器", "Servers")) {
                    ForEach(store.settings.hosts) { host in
                        HostSidebarRow(host: host, snap: engine.snapshots[host.id])
                            .tag(SettingsPage.host(host.id))
                    }
                    .onMove { from, to in store.settings.hosts.move(fromOffsets: from, toOffset: to) }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 230)
            .safeAreaInset(edge: .bottom) {
                Button { showingAdd = true } label: {
                    Label(L("添加服务器", "Add Server"), systemImage: "plus.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.18, green: 0.68, blue: 0.53))
                .padding(12)
            }
        } detail: {
            Group {
                switch selection {
                case .host(let id):
                    if let current = store.host(id) {
                        // 按服务器 ID 绑定（而不是数组下标）：切换页面、删除或调整顺序后，异步结果也不会写到别的服务器上。
                        HostDetailView(host: Binding(get: { store.host(id) ?? current },
                                                     set: { new in
                                                         if let i = store.settings.hosts.firstIndex(where: { $0.id == id }) {
                                                             store.settings.hosts[i] = new
                                                         }
                                                     }),
                                       engine: engine,
                                       globalInterval: store.settings.defaultInterval) {
                            store.settings.hosts.removeAll { $0.id == id }
                            selection = .general
                        }
                        .id(id)
                    } else {
                        GeneralSettingsView(store: store, engine: engine)
                    }
                case .rules:
                    ProgressRulesView(store: store, engine: engine)
                default:
                    GeneralSettingsView(store: store, engine: engine)
                }
            }
            // 标题栏用不透明背景：页面往下滚动时内容不会和标题重叠。
            .toolbarBackground(.visible, for: .windowToolbar)
        }
        .sheet(isPresented: $showingAdd) {
            AddHostSheet(existing: Set(store.settings.hosts.map(\.alias))) { newHosts in
                store.settings.hosts.append(contentsOf: newHosts)
                if let first = newHosts.first { selection = .host(first.id) }
            }
        }
        .onChange(of: store.settings.hosts) { _, _ in engine.sync() }
        .frame(minWidth: 760, minHeight: 520)
        // 切换语言后整页重绘。
        .id(store.settings.language)
    }
}

struct SidebarRow: View {
    var title: String
    var subtitle: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}

struct HostSidebarRow: View {
    var host: HostConfig
    var snap: HostSnapshot?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: host.kind == .slurm ? "square.stack.3d.up.fill" : "server.rack")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill((host.kind == .slurm ? Color.purple : Color.teal).gradient))
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(host.enabled ? Theme.color(for: snap?.health ?? .unknown) : Color.gray)
                        .frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(host.displayName).lineLimit(1)
                    if host.muted { Image(systemName: "bell.slash.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                    if host.paused { Image(systemName: "pause.fill").font(.system(size: 9)).foregroundStyle(.secondary) }
                }
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        guard host.enabled else { return L("已停用", "Disabled") }
        if host.paused { return L("已暂停", "Paused") }
        switch snap?.health ?? .unknown {
        case .ok:
            let r = snap?.runningCount ?? 0, p = snap?.pendingCount ?? 0
            return r + p == 0 ? host.kind.label + L(" · 空闲", " · idle") : L("运行 \(r) · 排队 \(p)", "\(r) running · \(p) pending")
        case .needsLogin: return L("需要登录", "Login required")
        case .error(let m): return m
        case .unknown: return L("连接中…", "Connecting…")
        }
    }
}

// MARK: - 通用

/// 项目的网址。
enum AppLinks {
    static let repo = URL(string: "https://github.com/zhyan0603/ServerIsland")!
    static let issues = URL(string: "https://github.com/zhyan0603/ServerIsland/issues")!
}

struct GeneralSettingsView: View {
    @ObservedObject var store: ConfigStore
    @ObservedObject var engine: MonitorEngine

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage)
                        .resizable().frame(width: 58, height: 58)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ServerIsland").font(.system(size: 20, weight: .bold, design: .rounded))
                        Text(L("版本 ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(L("\(store.settings.hosts.count) 台服务器 · 运行 \(engine.totalRunning) · 排队 \(engine.totalPending)",
                               "\(store.settings.hosts.count) servers · \(engine.totalRunning) running · \(engine.totalPending) pending"))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PetView(mood: engine.petMood, size: 40)
                }
                .padding(.vertical, 4)
                Picker(L("语言", "Language"), selection: $store.settings.language) {
                    ForEach(AppLanguage.allCases) { Text($0.label).tag($0) }
                }
                // 开源项目：请用户点 Star / 反馈问题
                HStack(spacing: 10) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(L("喜欢 ServerIsland？", "Enjoying ServerIsland?"))
                        Text(L("它是免费的开源软件，在 GitHub 上点个 Star 能让更多人看到它。",
                               "It's free and open source — a star on GitHub helps others find it."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        NSWorkspace.shared.open(AppLinks.repo)
                    } label: {
                        Label(L("点个 Star", "Star on GitHub"), systemImage: "star")
                    }
                    Button(L("反馈问题", "Report an Issue")) {
                        NSWorkspace.shared.open(AppLinks.issues)
                    }
                }
            }

            Section {
                Toggle(isOn: Binding(get: { store.settings.autoRefresh }, set: { engine.setAutoRefresh($0) })) {
                    HelpLabel(L("自动刷新", "Auto Refresh"),
                              help: L("关闭后只有点击刷新按钮时才会连接服务器。", "When off, servers are only contacted when you click Refresh."))
                }
                IntervalPicker(title: L("默认轮询间隔", "Default Interval"),
                               seconds: Binding(get: { store.settings.defaultInterval },
                                                set: { store.settings.defaultInterval = $0 ?? 60 }),
                               allowsInherit: false)
                    .disabled(!store.settings.autoRefresh)
            } header: { SettingsHeader(title: L("轮询", "Refresh"), symbol: "arrow.triangle.2.circlepath", tint: .blue) }

            Section {
                Picker(L("收起时", "When Collapsed"), selection: $store.settings.collapsedStyle) {
                    ForEach(CollapsedStyle.allCases) { Text($0.label).tag($0) }
                }
                Toggle(isOn: $store.settings.foldIdleHosts) {
                    HelpLabel(L("合并空闲的服务器", "Group Idle Servers"),
                              help: L("展开面板里，没有任务的服务器合并成一行，点击可以展开。全部空闲时照常显示。",
                                      "Servers with no jobs are grouped into one line you can click to expand. All cards show when everything is idle."))
                }
                Toggle(L("在刘海弹出提示", "Island Pop-ups"), isOn: $store.settings.islandAlerts)
                Toggle(L("系统通知", "System Notifications"), isOn: $store.settings.systemNotifications)
                Toggle(isOn: $store.settings.arrayFirstFailureAlert) {
                    HelpLabel(L("数组作业首个失败立即提醒", "Alert on First Array Failure"),
                              help: L("数组作业平时只在全部结束时提醒一次；打开后第一个元素失败时会额外提醒一次。",
                                      "Job arrays normally alert once when all elements finish; this adds one alert when the first element fails."))
                }
                Picker(selection: $store.settings.diskWarnThreshold) {
                    ForEach([0.8, 0.85, 0.9, 0.95], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                } label: {
                    HelpLabel(L("磁盘提醒阈值", "Disk Alert Threshold"),
                              help: L("超过时提醒一次；回落后再次超过会重新提醒。", "Alerts once when exceeded; alerts again after it drops and rises again."))
                }
            } header: { SettingsHeader(title: L("刘海与提醒", "Island & Alerts"), symbol: "bell.badge.fill", tint: .orange) }

            Section {
                Toggle(L("提示音", "Sounds"), isOn: $store.settings.soundEnabled)
                HStack {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $store.settings.soundVolume, in: 0.1...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                }
                .disabled(!store.settings.soundEnabled)
                HStack(spacing: 10) {
                    Text(L("试听", "Preview"))
                    Spacer()
                    Button { SoundPlayer.shared.preview(.success, volume: store.settings.soundVolume) } label: {
                        Label(L("成功", "Success"), systemImage: "checkmark.circle.fill")
                    }
                    Button { SoundPlayer.shared.preview(.failure, volume: store.settings.soundVolume) } label: {
                        Label(L("失败", "Failure"), systemImage: "xmark.circle.fill")
                    }
                    Button { SoundPlayer.shared.preview(.warning, volume: store.settings.soundVolume) } label: {
                        Label(L("提醒", "Warning"), systemImage: "exclamationmark.circle.fill")
                    }
                }
            } header: { SettingsHeader(title: L("提示音", "Sounds"), symbol: "speaker.wave.2.fill", tint: .pink) }

            Section {
                LaunchAtLoginToggle()
            } header: { SettingsHeader(title: L("启动", "Startup"), symbol: "power", tint: .green) }

            Section {
                Text(L("训练脚本往服务器的 ~/.serverisland/progress/<名称>.json 写一行 JSON，刘海里就能显示真实进度：",
                       "Have your script write one line of JSON to ~/.serverisland/progress/<name>.json on the server to show real progress:"))
                    .font(.callout)
                Text(#"{"name": "train", "progress": 0.42, "message": "epoch 3/10", "jobid": "$SLURM_JOB_ID"}"#)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            } header: {
                HStack {
                    SettingsHeader(title: L("进度文件", "Progress Files"), symbol: "chart.bar.fill", tint: .teal)
                    HelpLabel("", help: L("写了 jobid 的条目会合并到对应作业上（数组元素写 主编号_序号）。仓库里的 remote/si-progress 是现成的小工具。",
                                          "Entries with a jobid are merged into that job (array elements use base_index). remote/si-progress in the repo is a ready-made helper."))
                }
            }

            Section {
                LabeledContent(L("配置文件", "Config File")) {
                    Text(ConfigStore.fileURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                LabeledContent(L("诊断日志", "Diagnostic Log")) {
                    Text(DebugLog.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                }
                HStack {
                    Button(L("显示配置文件", "Show Config")) {
                        store.saveNow()
                        NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.fileURL])
                    }
                    Button(L("打开诊断日志", "Open Log")) { NSWorkspace.shared.open(DebugLog.url) }
                    Spacer()
                    Button(L("立即刷新全部", "Refresh All")) { engine.refreshAll() }
                }
            } header: { SettingsHeader(title: L("文件与诊断", "Files & Diagnostics"), symbol: "folder.fill", tint: .gray) }
        }
        .formStyle(.grouped)
        .navigationTitle(L("通用", "General"))
    }
}
