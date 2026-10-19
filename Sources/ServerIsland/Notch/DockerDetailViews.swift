import SwiftUI

/// 指标两列排布，资源条与百分比在同一行；图表和日志各自按需显示。
struct DockerContainerDetail: View {
    var host: HostConfig
    var container: DockerContainer
    @ObservedObject var engine: MonitorEngine
    var now: Date
    @State private var tab = 0
    @State private var liveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    Text(L("指标", "Metrics")).tag(0)
                    Text(L("运行日志", "Runtime Logs")).tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 165)
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
                MaybeScroll {
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
        .task(id: host.id.uuidString + "|" + container.id) {
            await engine.monitorDockerDetail(host: host, container: container.id) { result in
                liveError = result.message
            }
        }
    }

    private var metrics: some View {
        VStack(spacing: 8) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            DockerMetricCell(title: "CPU", value: DockerFormat.cpu(container.cpuUsagePercent),
                             fraction: container.cpuFraction, hasBar: true,
                             note: DockerFormat.cpuNote(container))
                .help(DockerFormat.cpuHelp(container))
            DockerMetricCell(title: L("内存", "Memory"), value: DockerFormat.percent(container.memoryFraction),
                             fraction: container.memoryFraction, hasBar: true,
                             note: DockerFormat.bytes(container.memoryUsed) + " / " + DockerFormat.bytes(container.memoryCapacity))
                .help(DockerFormat.memoryHelp(container))
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 8) {
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
                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .lineLimit(1).fixedSize(horizontal: true, vertical: false).layoutPriority(1)
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
    var host: HostConfig
    var containerID: String
    @ObservedObject var engine: MonitorEngine
    @State private var logs: DockerLogs?
    @State private var coloredLog = AttributedString()
    @State private var loading = false
    @State private var follow = true
    @AppStorage("dockerLogShowsTimestamps") private var showTimestamps = false
    @State private var tail = 200
    @State private var reload = 0
    @State private var activeRequest = UUID()
    @State private var terminalError: String?

    private var requestKey: String { "\(containerID)|\(follow)|\(tail)|\(reload)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $tail) {
                    Text(L("最近 200 行", "Last 200 Lines")).tag(200)
                    Text(L("最近 500 行", "Last 500 Lines")).tag(500)
                }.labelsHidden().pickerStyle(.menu).frame(width: 122)
                Toggle(L("时间戳", "Timestamps"), isOn: $showTimestamps).toggleStyle(.checkbox).font(Theme.rounded(10.5))
                Toggle(L("自动刷新", "Auto Refresh"), isOn: $follow).toggleStyle(.checkbox).font(Theme.rounded(10.5))
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.mini) }
                IslandIconButton(systemName: "terminal", help: L("在默认终端查看最近 \(tail) 行并跟踪日志", "View Last \(tail) Lines and Follow Logs in Default Terminal")) {
                    terminalError = DockerControl.openLogsTerminal(host: host, container: containerID,
                        socket: engine.snapshots[host.id]?.docker?.socket, tail: tail, showTimestamps: showTimestamps)
                }
                IslandIconButton(systemName: "arrow.clockwise", help: L("刷新日志", "Refresh Logs")) { reload += 1 }
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
                follow: follow)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
            if let time = logs?.fetchedAt {
                Text(L("更新于 ", "Updated ") + DockerFormat.date(time))
                    .font(Theme.rounded(9.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .onChange(of: showTimestamps) { _ in
            coloredLog = DockerLogText.render(logs?.text ?? "", showTimestamps: showTimestamps)
        }
        .task(id: requestKey) {
            let token = UUID()
            activeRequest = token
            var failures = 0
            repeat {
                guard !Task.isCancelled else { return }
                let started = Date()
                loading = true
                let result = await engine.fetchDockerLogs(host: host, container: containerID, tail: tail)
                guard !Task.isCancelled, activeRequest == token else { return }
                // 仅日志内容改变时解析颜色，避免每秒界面重绘重复处理长日志。
                if result.text != logs?.text { coloredLog = DockerLogText.render(result.text, showTimestamps: showTimestamps) }
                logs = result
                loading = false
                guard follow, DockerLivePolling.retries(result.error) else { return }
                failures = result.error == nil ? 0 : failures + 1
                let delay = DockerLivePolling.delay(elapsed: Date().timeIntervalSince(started), failures: failures)
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            } while !Task.isCancelled
        }
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
