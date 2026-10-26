import SwiftUI

/// 明确指定灰色选中层，避免窗口获得键盘焦点后系统分段控件切换为蓝色。
struct DockerDetailTabs: View, Equatable {
    var selected: Int
    var onSelect: (Int) -> Void
    private let localeKey = L("zh", "en")
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.selected == rhs.selected && lhs.localeKey == rhs.localeKey }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<2) { value in
                Button { onSelect(value) } label: {
                    Text(value == 0 ? L("指标", "Metrics") : L("运行日志", "Runtime Logs"))
                        .font(Theme.rounded(11.5, .semibold))
                        .foregroundStyle(selected == value ? Theme.text : Theme.secondary)
                        .frame(maxWidth: .infinity).frame(height: 20)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(selected == value ? 0.16 : 0)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected == value ? [.isSelected] : [])
            }
        }
        .padding(2).frame(width: 165, height: 24)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
        .transaction { $0.animation = nil }
    }
}

/// 指标两列排布，资源条与百分比在同一行；图表和日志各自按需显示。
struct DockerContainerDetail: View {
    @Environment(\.islandContentActive) private var contentActive
    var host: HostConfig
    var container: DockerContainer
    @ObservedObject var engine: MonitorEngine
    var now: Date
    @State private var tab = 0
    @State private var liveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                DockerDetailTabs(selected: tab) { tab = $0 }.equatable()
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    Text("PIDs " + (container.pids.map(String.init) ?? "—"))
                    Text(L("采样 ", "Sample ") + (container.sampledAt.map {
                        Date(timeIntervalSince1970: $0).formatted(date: .omitted, time: .standard)
                    } ?? "—"))
                }.font(Theme.rounded(10).monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
            }.frame(height: 24)
            if tab == 1 {
                DockerLogView(host: host, containerID: container.id, engine: engine)
            } else {
                DockerVerticalScroll {
                    VStack(alignment: .leading, spacing: 10) {
                        if let liveError { DockerNote(text: liveError, warning: true) }
                        if let error = container.statsError { DockerNote(text: DockerSnapshot.errorText(error), warning: true) }
                        metrics
                        DockerTimeChart(points: engine.dockerHistory.points(host: host.id, container: container.id), now: now,
                                        interval: DockerLivePolling.interval)
                        metadata
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .task(id: host.id.uuidString + "|" + container.id + "|\(contentActive)") {
            guard contentActive else { return }
            await engine.monitorDockerDetail(host: host, container: container.id) { result in
                liveError = result.message
            }
        }
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible(minimum: 0)), GridItem(.flexible(minimum: 0))], spacing: 8) {
            DockerMetricCell(title: "CPU", value: DockerFormat.cpu(container.cpuUsagePercent),
                             fraction: container.cpuFraction, hasBar: true,
                             note: DockerFormat.cpuNote(container))
                .help(DockerFormat.cpuHelp(container))
            DockerMetricCell(title: L("内存", "Memory"), value: DockerFormat.percent(container.memoryFraction),
                             fraction: container.memoryFraction, hasBar: true,
                             note: DockerFormat.bytes(container.memoryUsed) + " / " + DockerFormat.bytes(container.memoryCapacity))
                .help(DockerFormat.memoryHelp(container))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 0)), count: 4), spacing: 8) {
            DockerMetricCell(title: L("网络接收", "Network RX"), value: DockerFormat.rate(container.rxRate),
                             note: L("累计 ", "Total ") + DockerFormat.bytes(container.networkRx))
            DockerMetricCell(title: L("网络发送", "Network TX"), value: DockerFormat.rate(container.txRate),
                             note: L("累计 ", "Total ") + DockerFormat.bytes(container.networkTx))
            DockerMetricCell(title: L("磁盘读取", "Block Read"), value: DockerFormat.rate(container.readRate),
                             note: L("累计 ", "Total ") + DockerFormat.bytes(container.blockRead))
            DockerMetricCell(title: L("磁盘写入", "Block Write"), value: DockerFormat.rate(container.writeRate),
                             note: L("累计 ", "Total ") + DockerFormat.bytes(container.blockWrite))
            }
        }
    }

    private var metadata: some View {
        VStack(alignment: .leading, spacing: 8) {
            field(L("状态", "Status"), container.status.isEmpty ? container.stateLabel : container.status)
            field("ID", String(container.id.prefix(12)))
            field(L("镜像", "Image"), container.image)
            if !container.composeProject.isEmpty { field("Compose", container.composeProject + " / " + container.composeService) }
            if !container.ports.isEmpty { field(L("端口", "Ports"), container.ports.joined(separator: " · ")) }
            field(container.commandTitle, container.commandArguments.map { args in
                args.isEmpty ? "[]" : args.map { value in
                    value.range(of: #"\A[A-Za-z0-9_./:@%+=,-]+\z"#, options: .regularExpression) != nil ? value : SSHRunner.shellQuote(value)
                }.joined(separator: " ")
            } ?? "—")
            field(L("创建时间", "Created At"), DockerFormat.date(container.createdAt))
            field(L("最近变更", "Last Changed"), DockerFormat.date(container.updatedAt ?? container.createdAt))
        }
    }

    private func field(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).font(Theme.rounded(10)).foregroundStyle(Theme.tertiary).frame(width: 72, alignment: .leading)
            Text(value).font(Theme.mono(10)).foregroundStyle(Theme.secondary).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DockerMetricCell: View {
    var title: String
    var value: String
    var fraction: Double? = nil
    var hasBar = false
    var note: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(title).font(Theme.rounded(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
                Spacer(minLength: 0)
                if let note {
                    Text(note).font(Theme.rounded(9.5)).foregroundStyle(Theme.tertiary)
                        .lineLimit(1).minimumScaleFactor(0.8).help(note)
                }
            }
            HStack(spacing: 7) {
                if hasBar {
                    SlimBar(fraction: fraction, fill: AnyShapeStyle(Theme.load(fraction ?? 0)), height: 4)
                        .frame(maxWidth: .infinity)
                }
                Text(value).font(Theme.rounded(12, .medium)).foregroundStyle(Theme.text).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.75).layoutPriority(1)
                if !hasBar { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.085)))
    }
}

/// 日志仅驻留在当前页面内存；切换容器或离开页签后取消自动刷新。
struct DockerLogView: View {
    @Environment(\.islandContentActive) private var contentActive
    var host: HostConfig
    var containerID: String
    @ObservedObject var engine: MonitorEngine
    @State private var logs: DockerLogs?
    @State private var coloredLog = AttributedString()
    @State private var loading = false
    @State private var manualLoading = false
    @State private var logQuery = ""
    @State private var searchFocused = false
    @State private var matches = DockerLogMatches()
    @State private var selectedMatch = 0
    @State private var searchedText = ""
    @State private var jumpToken: UUID?
    @State private var follow = true
    @AppStorage("dockerLogShowsTimestamps") private var showTimestamps = false
    @State private var tail = 200
    @State private var reload = 0
    @State private var activeRequest = UUID()
    @State private var terminalError: String?

    private var requestKey: String { "\(containerID)|\(follow)|\(tail)|\(reload)|\(contentActive)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $tail) {
                    Text(L("最近 200 行", "Last 200 Lines")).tag(200)
                    Text(L("最近 500 行", "Last 500 Lines")).tag(500)
                }.labelsHidden().pickerStyle(.menu).frame(width: 122)
                Toggle(L("时间戳", "Timestamps"), isOn: $showTimestamps).toggleStyle(.checkbox).font(Theme.rounded(10.5))
                Toggle(L("自动刷新", "Auto Refresh"), isOn: $follow).toggleStyle(.checkbox).font(Theme.rounded(10.5))
                searchControls.frame(maxWidth: .infinity)
                if manualLoading { ProgressView().controlSize(.mini) }
                IslandIconButton(systemName: "terminal", help: L("在默认终端查看最近 \(tail) 行并跟踪日志", "View Last \(tail) Lines and Follow Logs in Default Terminal")) {
                    terminalError = DockerControl.openLogsTerminal(host: host, container: containerID,
                        socket: engine.snapshots[host.id]?.docker?.socket, tail: tail, showTimestamps: showTimestamps)
                }
                IslandIconButton(systemName: "arrow.clockwise", help: L("刷新日志", "Refresh Logs")) {
                    manualLoading = true; reload += 1
                }.disabled(manualLoading)
            }
            if let terminalError { DockerNote(text: terminalError, warning: true) }
            if let error = logs?.error {
                DockerNote(text: logs?.message ?? logError(error), warning: true)
            }
            if logs?.truncated == true {
                DockerNote(text: L("日志较长，已截断显示", "Log output was truncated"))
            }
            DockerLogScrollView(
                text: logs?.text.isEmpty == false ? coloredLog : AttributedString(loading && logs == nil
                    ? L("正在读取日志…", "Loading logs…") : L("暂无日志输出", "No log output")),
                follow: follow && logQuery.isEmpty, matches: matches, selectedMatch: selectedMatch, jumpToken: jumpToken)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            if let time = logs?.fetchedAt {
                Text(L("更新于 ", "Updated ") + DockerFormat.date(time))
                    .font(Theme.rounded(9.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .onChange(of: showTimestamps) { _ in
            coloredLog = DockerLogText.render(logs?.text ?? "", showTimestamps: showTimestamps)
            refreshMatches(reset: false, jump: false)
        }
        .onChange(of: logQuery) { _ in
            refreshMatches(reset: true, jump: true)
        }
        .task(id: requestKey) {
            guard contentActive else { return }
            let token = UUID()
            activeRequest = token
            let requestIdentity = requestKey
            defer {
                // 旧任务取消时不能清掉新一轮手动刷新的 loading。
                if activeRequest == token && requestKey == requestIdentity { loading = false; manualLoading = false }
            }
            var failures = 0
            repeat {
                guard !Task.isCancelled else { return }
                let started = Date()
                loading = true
                let result = await engine.fetchDockerLogs(host: host, container: containerID, tail: tail)
                guard !Task.isCancelled, activeRequest == token else { return }
                // 仅日志内容改变时解析颜色，避免每秒界面重绘重复处理长日志。
                if result.text != logs?.text {
                    coloredLog = DockerLogText.render(result.text, showTimestamps: showTimestamps)
                    refreshMatches(reset: false, jump: false)
                }
                logs = result
                loading = false
                manualLoading = false
                guard follow, DockerLivePolling.retries(result.error) else { return }
                failures = result.error == nil ? 0 : failures + 1
                let delay = DockerLivePolling.delay(elapsed: Date().timeIntervalSince(started), failures: failures)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            } while !Task.isCancelled
        }
    }

    private var searchControls: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                ZStack(alignment: .leading) {
                    if logQuery.isEmpty {
                        Text(L("搜索当前日志", "Search loaded logs")).font(Theme.rounded(11.5))
                            .foregroundStyle(Theme.tertiary).allowsHitTesting(false)
                    }
                    DockerSearchInput(text: $logQuery, focused: $searchFocused,
                                      label: L("搜索当前日志", "Search loaded logs"), redirectReadOnlyText: true,
                                      onSubmit: { if !matches.ranges.isEmpty { moveMatch(1) } })
                }.frame(height: 18)
                if !logQuery.isEmpty {
                    Button { logQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                    }.buttonStyle(.plain).islandHelp(L("清除搜索", "Clear Search"))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(searchFocused ? 0.12 : 0.07)))
            if !logQuery.isEmpty {
                Text("\(matches.ranges.isEmpty ? 0 : selectedMatch + 1)/\(matches.ranges.count)" + (matches.capped ? "+" : ""))
                    .font(Theme.mono(10)).foregroundStyle(Theme.tertiary).fixedSize()
                IslandIconButton(systemName: "chevron.up", help: L("上一个匹配", "Previous Match")) { moveMatch(-1) }
                    .disabled(matches.ranges.isEmpty)
                IslandIconButton(systemName: "chevron.down", help: L("下一个匹配", "Next Match")) { moveMatch(1) }
                    .disabled(matches.ranges.isEmpty)
            }
        }
    }

    /// 刷新只重算命中与保留当前项；只有用户输入或点击定位按钮才滚动到匹配位置。
    private func refreshMatches(reset: Bool, jump: Bool) {
        let text = String(coloredLog.characters)
        let previous = matches.ranges.indices.contains(selectedMatch) ? matches.ranges[selectedMatch] : nil
        let fresh = DockerLogMatches.find(in: text, query: logQuery)
        selectedMatch = reset ? 0 : fresh.retainedIndex(previous: previous, oldText: searchedText, newText: text)
        matches = fresh
        searchedText = text
        if jump { jumpToken = UUID() }
    }

    private func moveMatch(_ direction: Int) {
        selectedMatch = DockerLogMatches.step(selectedMatch, count: matches.ranges.count, direction: direction)
        jumpToken = UUID()
    }

    private func logError(_ code: String) -> String {
        switch code {
        case "container_missing": return L("容器已移除，无法读取日志", "Container was removed; logs are unavailable")
        case "logs_unavailable": return L("Docker 日志驱动未提供可读取的日志", "The Docker logging driver does not provide readable logs")
        case "invalid_container": return L("容器标识无效或 Docker 监控已关闭", "Invalid container ID or Docker monitoring is disabled")
        default: return DockerSnapshot.errorText(code)
        }
    }
}
