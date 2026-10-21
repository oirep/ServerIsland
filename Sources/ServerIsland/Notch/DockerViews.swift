import SwiftUI

/// 紧凑工具保持原尺寸，悬停亮度沿用主机右侧操作按钮。
struct DockerToolbarHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(hovering ? 0.14 : 0)))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
    }
}

/// 两个入口复用紧凑控件，布局值由各自的偏好提供。
struct DockerListControls: View, Equatable {
    var mode: DockerViewMode
    var sort: DockerSortOrder
    var onMode: (DockerViewMode) -> Void
    var onSort: (DockerSortOrder) -> Void
    private let localeKey = L("zh", "en")

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.mode == rhs.mode && lhs.sort == rhs.sort && lhs.localeKey == rhs.localeKey
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(DockerViewMode.allCases, id: \.self) { value in
                Button { onMode(value) } label: {
                    Image(systemName: value == .list ? "list.bullet" : "square.grid.2x2")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(mode == value ? Theme.cyan : Theme.tertiary)
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(mode == value ? Theme.cyan.opacity(0.12) : .clear))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .modifier(DockerToolbarHover())
                .islandHelp(value == .list ? L("列表视图", "List View") : L("网格视图", "Grid View"))
            }
            Menu {
                ForEach(DockerSortOrder.allCases, id: \.self) { value in
                    Button { onSort(value) } label: {
                        if value == sort { Label(value.label, systemImage: "checkmark") }
                        else { Text(value.label) }
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .resizable().scaledToFit().frame(width: 9, height: 9)
                    .foregroundStyle(Theme.tertiary).frame(width: 22, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).controlSize(.mini)
            .foregroundStyle(Theme.tertiary).frame(width: 22, height: 18)
            .modifier(DockerToolbarHover())
            .islandHelp(L("排序：", "Sort: ") + sort.label)
        }
    }
}

/// 固定高度与 IslandLayout 一致，视图切换不依赖事后测量。
struct DockerCardSection: View {
    var snapshot: DockerSnapshot?
    var mode: DockerViewMode
    var sort: DockerSortOrder
    var now: Date
    var favorites: Set<String> = []
    var onMode: (DockerViewMode) -> Void
    var onSort: (DockerSortOrder) -> Void
    var onOpen: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: IslandLayout.jobGap) {
            HStack(spacing: 6) {
                Image(systemName: "shippingbox.fill").foregroundStyle(Theme.cyan)
                Text("Docker").foregroundStyle(Theme.text)
                if let snapshot, snapshot.error == nil {
                    Text(L("\(snapshot.running)/\(snapshot.total) 运行中", "\(snapshot.running)/\(snapshot.total) running"))
                        .foregroundStyle(Theme.tertiary)
                }
                Spacer(minLength: 4)
                DockerListControls(mode: mode, sort: sort, onMode: onMode, onSort: onSort)
                    .equatable()
                Button { onOpen(nil) } label: {
                    HStack(spacing: 3) {
                        Text(L("查看全部", "Show All"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }.foregroundStyle(Theme.cyan)
                        .frame(minHeight: 18).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .modifier(DockerToolbarHover())
            }
            .font(Theme.rounded(10.5, .medium))
            .frame(height: IslandLayout.dockerHeader)
            if let snapshot, snapshot.error == nil, snapshot.containers.contains(where: { !$0.isStopped }) {
                DockerContainerCollection(containers: Array(sort.sorted(snapshot.containers.filter { !$0.isStopped }, favorites: favorites).prefix(mode == .grid ? 4 : IslandLayout.maxDockerContainers)),
                                          mode: mode, now: now, decorated: false) { onOpen($0.id) }
            } else {
                Text(snapshot?.error.map(DockerSnapshot.errorText) ?? (snapshot == nil ? L("等待采集 Docker 指标…", "Waiting for Docker metrics…") : L("暂无运行中的容器", "No active containers")))
                    .font(Theme.rounded(10.5))
                    .foregroundStyle(snapshot?.error == nil ? Theme.tertiary : Theme.amber)
                    .lineLimit(1).islandHelp(snapshot?.error.map(DockerSnapshot.errorText) ?? "")
                    .frame(height: IslandLayout.emptyRow)
            }
        }
    }
}

struct DockerContainerCollection: View {
    var containers: [DockerContainer]
    var mode: DockerViewMode
    var now: Date
    var decorated = true
    var groupStopped = false
    var favorites: Set<String> = []
    var onFavorite: ((DockerContainer) -> Void)? = nil
    var onOpen: (DockerContainer) -> Void

    var body: some View {
        if mode == .grid {
            if groupStopped {
                VStack(spacing: IslandLayout.jobGap) {
                    grid(containers.filter { favorites.contains($0.name) })
                    grid(containers.filter { !favorites.contains($0.name) && !$0.isStopped })
                    grid(containers.filter { !favorites.contains($0.name) && $0.isStopped })
                }
            } else { grid(containers) }
        } else {
            VStack(spacing: IslandLayout.jobGap) {
                ForEach(containers) { container in
                    DockerContainerRow(container: container, now: now,
                                       isFavorite: favorites.contains(container.name),
                                       onFavorite: onFavorite.map { action in { action(container) } }) { onOpen(container) }
                        .equatable()
                        .padding(decorated ? 8 : 0)
                        .background(RoundedRectangle(cornerRadius: 10).fill(decorated ? Theme.card : .clear))
                        .modifier(DockerContainerHover())
                }
            }
        }
    }

    @ViewBuilder private func grid(_ items: [DockerContainer]) -> some View {
        if !items.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: IslandLayout.jobGap) {
                ForEach(items) { container in
                    DockerContainerTile(container: container, now: now,
                                        isFavorite: favorites.contains(container.name),
                                        onFavorite: onFavorite.map { action in { action(container) } }) { onOpen(container) }
                        .equatable()
                }
            }
        }
    }
}

/// 首页与全部容器共用任务行的浅白悬停高亮，不改变尺寸或资源刷新逻辑。
private struct DockerContainerHover: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0))
                    .allowsHitTesting(false)
            }
            .onHover { hovering = $0 }
    }
}

struct DockerResourceValue: View {
    var title: String
    var value: String
    var fraction: Double?
    var barWidth: CGFloat = 30
    var body: some View {
        HStack(spacing: 5) {
            if !title.isEmpty { Text(title).foregroundStyle(Theme.tertiary) }
            SlimBar(fraction: fraction, fill: AnyShapeStyle(Theme.load(fraction ?? 0)), height: 3)
                .frame(width: barWidth)
            Text(value).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
        }.font(Theme.rounded(10))
    }
}

struct DockerContainerStatus: View {
    var container: DockerContainer
    var now: Date
    var body: some View {
        HStack(spacing: 5) {
            Text(container.stateLabel)
                .foregroundStyle(DockerContainerRow.color(container))
            if !container.status.isEmpty {
                Text(container.status).foregroundStyle(Theme.tertiary)
            }
        }
        .font(Theme.rounded(10))
        .lineLimit(1).truncationMode(.tail)
        .islandHelp(container.status)
    }
}

struct DockerContainerRow: View, Equatable {
    var container: DockerContainer
    var now = Date()
    var isFavorite = false
    var onFavorite: (() -> Void)? = nil
    var onOpen: () -> Void
    private let localeKey = L("zh", "en")

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.container == rhs.container && lhs.isFavorite == rhs.isFavorite
            && (lhs.onFavorite == nil) == (rhs.onFavorite == nil) && lhs.localeKey == rhs.localeKey
    }

    static func color(_ container: DockerContainer) -> Color {
        if container.health == "unhealthy" || container.state == "dead" { return Theme.coral }
        if container.state == "running" { return container.health == "starting" ? Theme.amber : Theme.mint }
        return container.state == "restarting" || container.state == "paused" ? Theme.amber : Theme.tertiary
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                Circle().fill(Self.color(container)).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 2) {
                    Text(container.name).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                    DockerContainerStatus(container: container, now: now)
                }.frame(maxWidth: .infinity, alignment: .leading)
                DockerResourceValue(title: "CPU", value: DockerFormat.cpu(container.cpuUsagePercent), fraction: container.cpuFraction)
                    .islandHelp(DockerFormat.cpuHelp(container))
                    .frame(width: 110, alignment: .trailing)
                DockerResourceValue(title: L("内存", "Mem"), value: DockerFormat.percent(container.memoryFraction), fraction: container.memoryFraction)
                    .islandHelp(DockerFormat.memoryHelp(container))
                    .frame(width: 105, alignment: .trailing)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.tertiary)
                    .frame(width: onFavorite == nil ? nil : 22).opacity(onFavorite == nil ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(height: IslandLayout.jobRow)
        .overlay(alignment: .trailing) {
            if let onFavorite { DockerFavoriteButton(active: isFavorite, action: onFavorite) }
        }
        .islandHelp(container.name + " · " + container.image + (container.statsError.map { " · " + DockerSnapshot.errorText($0) } ?? ""))
    }
}

struct DockerContainerTile: View, Equatable {
    var container: DockerContainer
    var now: Date
    var isFavorite = false
    var onFavorite: (() -> Void)? = nil
    var onOpen: () -> Void
    private let localeKey = L("zh", "en")

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.container == rhs.container && lhs.isFavorite == rhs.isFavorite
            && (lhs.onFavorite == nil) == (rhs.onFavorite == nil) && lhs.localeKey == rhs.localeKey
    }

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Circle().fill(DockerContainerRow.color(container)).frame(width: 5, height: 5)
                    Text(container.name).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.text)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.system(size: 7, weight: .bold)).foregroundStyle(Theme.tertiary)
                        .frame(width: onFavorite == nil ? nil : 22, height: onFavorite == nil ? nil : 20)
                        .fixedSize().opacity(onFavorite == nil ? 1 : 0)
                        .anchorPreference(key: DockerFavoriteSlotKey.self, value: .bounds) { $0 }
                }
                DockerContainerStatus(container: container, now: now)
                HStack(spacing: 10) {
                    DockerResourceValue(title: "CPU", value: DockerFormat.cpu(container.cpuUsagePercent), fraction: container.cpuFraction, barWidth: 24)
                        .islandHelp(DockerFormat.cpuHelp(container))
                    Spacer(minLength: 0)
                    DockerResourceValue(title: L("内存", "Mem"), value: DockerFormat.percent(container.memoryFraction), fraction: container.memoryFraction, barWidth: 24)
                        .islandHelp(DockerFormat.memoryHelp(container))
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: IslandLayout.dockerTile)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .islandHelp(container.image)
        // 用标题行实际预留位置对齐星标；按钮放在主卡片按钮之外，避免点击收藏同时进入详情。
        .overlayPreferenceValue(DockerFavoriteSlotKey.self) { anchor in
            GeometryReader { geometry in
                if let onFavorite, let anchor {
                    let slot = geometry[anchor]
                    DockerFavoriteButton(active: isFavorite, action: onFavorite)
                        .position(x: slot.midX, y: slot.midY)
                }
            }
            .allowsHitTesting(onFavorite != nil)
        }
        .modifier(DockerContainerHover())
    }
}

private struct DockerFavoriteSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

/// 星标独立于进入详情的按钮，点击收藏不会同时打开容器。
private struct DockerFavoriteButton: View {
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: active ? "star.fill" : "star")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.tertiary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(DockerToolbarHover())
        .islandHelp(active ? L("取消收藏", "Unfavorite") : L("收藏容器", "Favorite Container"))
        .accessibilityLabel(active ? L("取消收藏", "Unfavorite") : L("收藏容器", "Favorite Container"))
    }
}

enum DockerFormat {
    static func cpuNote(_ item: DockerContainer) -> String {
        if let cores = item.cpuLimitCores, cores > 0 {
            return L("限额 ", "Limit ") + String(format: "%.2g", cores) + L(" 核", " cores")
        }
        return item.limitsRead == true ? L("未限额 · 单核口径", "No limit · per core") : L("限额未知 · 单核口径", "Unknown limit · per core")
    }
    static func cpuHelp(_ item: DockerContainer) -> String {
        let raw = L("Docker 原始 CPU：", "Docker raw CPU: ") + cpu(item.cpuPercent)
        if let cores = item.cpuLimitCores, cores > 0 {
            return raw + L("；当前百分比和资源条按容器 ", "; percentage and bar use the container's ")
                + String(format: "%.2g", cores) + L(" 核限额计算。", " core limit.")
        }
        return raw + (item.limitsRead == true
            ? L("；未设置容器 CPU 硬限额，100% 表示 1 个核心，超过 100% 时资源条填满。", "; no container CPU hard limit. 100% equals one core; the bar fills at 100%.")
            : L("；无法确认容器限额，暂按单核 100% 显示。", "; container limits could not be read. Using 100% per core."))
    }
    static func memoryHelp(_ item: DockerContainer) -> String {
        let value = bytes(item.memoryUsed) + " / " + bytes(item.memoryCapacity)
        if (item.memoryConfiguredLimit ?? 0) > 0 { return L("容器内存占用 / 有效限额：", "Container memory / effective limit: ") + value }
        return (item.limitsRead == true
            ? L("未设置容器内存限额，按 daemon 报告的可用上限计算：", "No container memory limit; using the capacity reported by the daemon: ")
            : L("按 daemon 报告的内存上限计算：", "Using the memory limit reported by the daemon: ")) + value
    }
    static func cpu(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0) } ?? "—" }
    static func percent(_ value: Double?) -> String { value.map { String(format: "%.1f%%", $0 * 100) } ?? "—" }
    static func bytes(_ value: Double?) -> String {
        value.map { $0 < 1_048_576 ? String(format: "%.1fK", $0 / 1024) : Format.bytes($0) } ?? "—"
    }
    static func rate(_ value: Double?) -> String { value == nil ? "—" : bytes(value) + "/s" }
    static func date(_ value: Double?) -> String {
        value.map { Date(timeIntervalSince1970: $0).formatted(date: .numeric, time: .standard) } ?? "—"
    }
}

/// 搜索只筛选本机已有列表，不随输入触发 SSH；多个词可分别匹配名称、镜像或 Compose 信息。
enum DockerContainerSearch {
    static func matches(_ item: DockerContainer, query: String) -> Bool {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        let fields = [item.name, item.id, item.image, item.composeProject, item.composeService]
        return terms.allSatisfy { term in fields.contains { $0.localizedStandardContains(term) } }
    }
}

/// 状态筛选与文本搜索叠加，仅改变本地展示；收藏按当前主机配置判断。
enum DockerContainerFilter: CaseIterable {
    case all, favorites, running, stopped, unhealthy
    var label: String {
        switch self {
        case .all: return L("全部", "All")
        case .favorites: return L("收藏", "Favorites")
        case .running: return L("运行中", "Running")
        case .stopped: return L("已停止", "Stopped")
        case .unhealthy: return L("不健康", "Unhealthy")
        }
    }
    func matches(_ item: DockerContainer, favorites: Set<String>) -> Bool {
        switch self {
        case .all: return true
        case .favorites: return favorites.contains(item.name)
        case .running: return item.state == "running"
        case .stopped: return item.isStopped
        case .unhealthy: return item.health == "unhealthy"
        }
    }
}

struct DockerPage: View {
    var host: HostConfig
    @ObservedObject var engine: MonitorEngine
    var onBack: () -> Void
    @State var selectedID: String?
    @State private var clockStart = Date()
    @State private var pendingControl: DockerControlRequest?
    @State private var controlError: String?
    @State private var showControlError = false
    @State private var listError: String?
    @State private var manualRefreshID: UUID?
    @State private var query = ""
    @State private var filter: DockerContainerFilter = .all
    @State private var searching = false

    private var snapshot: DockerSnapshot? { engine.snapshots[host.id]?.docker }
    private var selected: DockerContainer? { snapshot?.containers.first { $0.id == selectedID } }
    private var filteredContainers: [DockerContainer] {
        host.dockerSort.sorted((snapshot?.containers ?? []).filter {
            filter.matches($0, favorites: Set(host.dockerFavorites)) && DockerContainerSearch.matches($0, query: query)
        },
                               favorites: Set(host.dockerFavorites))
    }
    private var subtitle: String {
        guard selectedID == nil, let snapshot, snapshot.error == nil else { return host.displayName }
        let count = host.displayName + " · " + L("\(snapshot.running)/\(snapshot.total) 运行中", "\(snapshot.running)/\(snapshot.total) running")
        return query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? count
            : count + " · " + L("找到 \(filteredContainers.count) 项", "\(filteredContainers.count) matches")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            ZStack(alignment: .leading) {
                if query.isEmpty {
                    Text(L("搜索容器", "Search containers"))
                        .font(Theme.rounded(11.5)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).allowsHitTesting(false)
                }
                DockerSearchInput(text: $query, focused: $searching,
                                  label: L("搜索 Docker 容器", "Search Docker containers"))
            }
            .frame(height: 18)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).islandHelp(L("清除搜索", "Clear Search"))
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(Color.white.opacity(searching ? 0.12 : 0.07)))
        .frame(width: 170)
        .islandHelp(L("按容器名称、ID、镜像或 Compose 项目/服务搜索；多个词用空格分隔", "Search name, ID, image or Compose project/service; separate terms with spaces"))
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(DockerContainerFilter.allCases, id: \.self) { value in
                Button { filter = value } label: {
                    Text(value.label).font(Theme.rounded(10.5, .semibold))
                        .foregroundStyle(filter == value ? Theme.text : Theme.tertiary)
                        .padding(.horizontal, 10).padding(.vertical, 3.5)
                        .background(Capsule().fill(Color.white.opacity(filter == value ? 0.14 : 0.04)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(filter == value ? [.isSelected] : [])
            }
            Spacer(minLength: 0)
            Text(L("\(filteredContainers.count) 项", "\(filteredContainers.count) items"))
                .font(Theme.rounded(10.5)).foregroundStyle(Theme.tertiary)
        }
    }

    var body: some View {
        TimelineView(.periodic(from: clockStart, by: 1)) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    IslandIconButton(systemName: "chevron.left", help: L("返回", "Back")) {
                        if selectedID != nil { selectedID = nil } else { onBack() }
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(selected?.name ?? "Docker")
                            .font(Theme.rounded(13.5, .semibold)).foregroundStyle(Theme.text)
                            .lineLimit(1).truncationMode(.middle)
                        Text(subtitle).font(Theme.rounded(10.5)).foregroundStyle(Theme.tertiary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer(minLength: 8)
                    if selectedID == nil { searchField }
                    if manualRefreshID != nil { ProgressView().controlSize(.mini) }
                    if selectedID == nil {
                        DockerListControls(mode: host.dockerAllView, sort: host.dockerSort,
                                           onMode: { engine.setDockerView(host: host.id, mode: $0, allContainers: true) },
                                           onSort: { engine.setDockerView(host: host.id, sort: $0) })
                            .equatable()
                    }
                    if let container = selected {
                        controlButtons(container)
                    }
                    IslandIconButton(systemName: "arrow.clockwise", help: selectedID == nil ? L("刷新容器列表", "Refresh Container List") : L("刷新容器指标", "Refresh Container Metrics")) {
                        manualRefreshID = UUID()
                    }
                    .disabled(manualRefreshID != nil)
                }
                .frame(height: 30)
                if selectedID == nil { filterBar }
                if let container = selected {
                    DockerContainerDetail(host: host, container: container, engine: engine, now: context.date).id(container.id)
                } else {
                    DockerVerticalScroll {
                        VStack(alignment: .leading, spacing: 10) {
                            if let listError { DockerNote(text: listError, warning: true) }
                            if let error = snapshot?.error {
                                DockerNote(text: DockerSnapshot.errorText(error), warning: true)
                            } else if selectedID != nil {
                                DockerNote(text: L("容器已不在当前列表中", "Container is no longer in the current list"))
                            } else if let snapshot {
                                if snapshot.truncated || snapshot.sampleLimited {
                                    DockerNote(text: L("最多列出 200 个容器，每次采集前 16 个运行容器的资源；未采样指标显示 —", "Lists up to 200 containers; samples the first 16 running containers. Unavailable metrics show —."))
                                }
                                DockerContainerCollection(containers: filteredContainers, mode: host.dockerAllView,
                                                          now: context.date, groupStopped: true, favorites: Set(host.dockerFavorites),
                                                          onFavorite: { engine.toggleDockerFavorite(host: host.id, name: $0.name) }) { selectedID = $0.id }
                                if snapshot.containers.isEmpty { DockerNote(text: L("暂无容器", "No containers")) }
                                else if filteredContainers.isEmpty { DockerNote(text: L("没有匹配的容器", "No matching containers")) }
                            } else {
                                DockerNote(text: L("等待采集 Docker 指标…", "Waiting for Docker metrics…"))
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(IslandLayout.cardPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .task(id: selectedID) {
                guard selectedID == nil else { return }
                await engine.monitorDockerList(host: host) { result in listError = result.message }
            }
            .task(id: manualRefreshID) {
                guard let refreshID = manualRefreshID else { return }
                defer { if manualRefreshID == refreshID { manualRefreshID = nil } }
                if let selectedID {
                    let key = host.id.uuidString + "|" + selectedID
                    while engine.dockerLiveRequests.contains(key) {
                        do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    }
                    guard !Task.isCancelled else { return }
                    _ = await engine.refreshDockerDetail(host: host, container: selectedID)
                } else {
                    let result = await engine.refreshDockerList(host: host, waitForCurrent: true)
                    guard !Task.isCancelled else { return }
                    listError = result.message
                }
            }
            .overlayPreferenceValue(DockerControlAnchorKey.self) { anchors in
                GeometryReader { geometry in
                    if let request = pendingControl, let anchor = anchors[request.action.rawValue] {
                        let button = geometry[anchor]
                        let width = min(280, max(0, geometry.size.width - 16))
                        let left = min(max(8, button.midX - width / 2), max(8, geometry.size.width - width - 8))
                        Color.black.opacity(0.001).contentShape(Rectangle())
                            .onTapGesture { pendingControl = nil }
                        DockerControlBubble(action: request.action, containerName: request.name,
                                            hostName: host.displayName, containerID: request.container,
                                            arrowX: button.midX - left,
                                            onCancel: { pendingControl = nil },
                                            onConfirm: { perform(request) })
                            .frame(width: width)
                            .offset(x: left, y: button.maxY + 5)
                    }
                }
                .allowsHitTesting(pendingControl != nil)
            }
            .onChange(of: selectedID) { _ in manualRefreshID = nil; searching = false }
            .onChange(of: selected?.id) { _ in pendingControl = nil }
            .onChange(of: selected?.state) { _ in pendingControl = nil }
            .alert(L("容器操作", "Container Action"), isPresented: $showControlError) {
                Button(L("好", "OK"), role: .cancel) {}
            } message: { Text(controlError ?? "") }
        }
    }

    private func controlButtons(_ container: DockerContainer) -> some View {
        let busy = engine.dockerControlRequests.contains(host.id.uuidString + "|" + container.id)
        return HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.mini) }
            if container.state == "created" || container.state == "exited" {
                IslandIconButton(systemName: "play.fill", help: L("启动容器", "Start Container")) { request(.start, container) }
                    .disabled(busy)
                    .anchorPreference(key: DockerControlAnchorKey.self, value: .bounds) { [DockerControlAction.start.rawValue: $0] }
            } else {
                IslandIconButton(systemName: "arrow.triangle.2.circlepath", help: L("重启容器", "Restart Container")) { request(.restart, container) }
                    .disabled(busy || container.state == "paused" || container.state == "dead")
                    .anchorPreference(key: DockerControlAnchorKey.self, value: .bounds) { [DockerControlAction.restart.rawValue: $0] }
            }
            IslandIconButton(systemName: "stop.fill", help: L("停止容器", "Stop Container")) { request(.stop, container) }
                .disabled(busy || !["running", "restarting"].contains(container.state))
                .anchorPreference(key: DockerControlAnchorKey.self, value: .bounds) { [DockerControlAction.stop.rawValue: $0] }
            IslandIconButton(systemName: "terminal", help: L("使用默认终端进入容器", "Enter Container in Default Terminal")) {
                if let error = DockerControl.openTerminal(host: host, container: container.id, socket: snapshot?.socket) {
                    controlError = error; showControlError = true
                }
            }.disabled(busy || container.state != "running")
        }
    }

    private func request(_ action: DockerControlAction, _ container: DockerContainer) {
        pendingControl = DockerControlRequest(action: action, container: container.id, name: container.name)
    }

    private func perform(_ request: DockerControlRequest) {
        pendingControl = nil
        Task {
            let error = await engine.controlDocker(host: host, container: request.container, action: request.action, confirmed: true)
            if let error { controlError = error; showControlError = true }
            _ = await engine.refreshDockerDetail(host: host, container: request.container)
        }
    }
}

private struct DockerControlRequest {
    var action: DockerControlAction
    var container: String
    var name: String
}

struct DockerNote: View {
    var text: String
    var warning = false
    var body: some View {
        Text(text).font(Theme.rounded(11)).foregroundStyle(warning ? Theme.amber : Theme.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
