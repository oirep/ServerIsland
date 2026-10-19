import SwiftUI

struct HostCard: View {
    var host: HostConfig
    var snap: HostSnapshot
    var now: Date
    var onLogin: () -> Void
    var onRefresh: () -> Void
    var onOpenJob: (RemoteJob) -> Void = { _ in }
    var onHistory: () -> Void = {}
    var onPicker: () -> Void = {}
    var onAllJobs: () -> Void = {}
    var onPartitions: () -> Void = {}
    var onSwitchToDirect: () -> Void = {}
    var onTogglePause: () -> Void = {}
    var onSetInterval: (Int?) -> Void = { _ in }
    var globalInterval = 60
    var globalAuto = true
    var onToggleMute: () -> Void = {}
    var loggingIn = false
    var onRunAction: (HostAction) -> Void = { _ in }
    var actionIsRunning: (HostAction) -> Bool = { _ in false }
    var onDocker: (String?) -> Void = { _ in }
    var onDockerMode: (DockerViewMode) -> Void = { _ in }
    var onDockerSort: (DockerSortOrder) -> Void = { _ in }

    var body: some View {
        let p = IslandLayout.parts(host, snap)
        VStack(alignment: .leading, spacing: 0) {
            header.frame(height: IslandLayout.cardHeader)
            if p.paused {
                gap
                HStack(spacing: 6) {
                    Image(systemName: "pause.circle.fill").font(.system(size: 10.5))
                    Text(snap.lastUpdate.map { L("自动刷新已暂停 · 数据停在 \(Format.relative($0, now: now))", "Auto refresh paused · data from \(Format.relative($0, now: now))") } ?? L("自动刷新已暂停 · 不会连接这台服务器", "Auto refresh paused · not contacting this server"))
                    Spacer(minLength: 6)
                    Button(action: onRefresh) {
                        Label(L("刷新一次", "Refresh Once"), systemImage: "arrow.clockwise").font(Theme.rounded(10, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.cyan)
                    Button(action: onTogglePause) {
                        Label(L("恢复", "Resume"), systemImage: "play.fill").font(Theme.rounded(10, .semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.mint)
                }
                .font(Theme.rounded(10.5))
                .foregroundStyle(Theme.amber.opacity(0.9))
                .frame(height: IslandLayout.emptyRow)
            }

            if p.problem { gap; problemRow.frame(height: IslandLayout.problemRow) }
            if p.connecting {
                gap
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text(L("正在连接…", "Connecting…")).font(Theme.rounded(11)).foregroundStyle(Theme.tertiary)
                }
                .frame(height: IslandLayout.emptyRow)
            }
            if p.metrics {
                gap
                metrics.frame(height: p.actions ? IslandLayout.actionMetricsRow : IslandLayout.metricsRow)
                    .opacity(host.paused && !p.actions ? 0.45 : 1)
            }
            if p.warnings > 0 {
                Spacer().frame(height: 6)
                ForEach(snap.warnings, id: \.self) { w in
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.circle.fill").font(.system(size: 9))
                        Text(Self.isMissingSqueue(w, host) ? L("这台机器上没有 squeue，可能不是 Slurm 集群", "squeue not found — check Environment settings") : w)
                            .lineLimit(1).truncationMode(.middle)
                        if Self.isMissingSqueue(w, host) {
                            Spacer(minLength: 4)
                            Button(action: onSwitchToDirect) {
                                Text(L("改为直连服务器", "Switch to Direct")).font(Theme.rounded(9.5, .bold))
                                    .padding(.horizontal, 7).padding(.vertical, 1.5)
                                    .background(Capsule().fill(Theme.amber.opacity(0.2)))
                            }
                            .buttonStyle(.plain)
                            .help(L("如果是集群但 squeue 不在 PATH 里，请改在 设置 → 高级 → 前置命令 里加 module load slurm", "If Slurm is installed but not on PATH, add e.g. module load slurm under Settings → Environment → Run First"))
                        }
                    }
                    .font(Theme.rounded(10))
                    .foregroundStyle(Theme.amber.opacity(0.85))
                    .frame(height: IslandLayout.warningRow)
                    .help(w + L("\n可以在 设置 → 高级命令 里调整", "\nAdjust under Settings → Advanced"))
                }
            }
            if p.docker {
                gap
                DockerCardSection(snapshot: snap.docker, mode: host.dockerView, sort: host.dockerSort, now: now,
                                  favorites: Set(host.dockerFavorites),
                                  onMode: onDockerMode, onSort: onDockerSort, onOpen: onDocker)
                    .opacity(host.paused ? 0.45 : 1)
            }
            if p.jobRows > 0 {
                gap
                VStack(spacing: IslandLayout.jobGap) {
                    ForEach(IslandLayout.visibleJobs(snap).prefix(IslandLayout.maxJobs)) { job in
                        JobRowButton(job: job, kind: host.kind, now: now, sampledAt: host.paused ? nil : snap.lastUpdate) { onOpenJob(job) }
                            .frame(height: IslandLayout.jobRow)
                            .opacity(host.paused ? 0.45 : 1)
                    }
                }
            }
            if p.more > 0 {
                Spacer().frame(height: 4)
                Button(action: onAllJobs) {
                    HStack(spacing: 4) {
                        Text(L("还有 \(p.more) 个任务，查看全部", "\(p.more) more — show all"))
                        Image(systemName: "chevron.right").font(.system(size: 8, weight: .bold))
                    }
                    .font(Theme.rounded(10, .medium))
                    .foregroundStyle(Theme.cyan.opacity(0.9))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(height: IslandLayout.moreRow)
                .padding(.leading, 32)
            }
            if p.emptyJobs {
                gap
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill").font(.system(size: 9.5))
                    Text(host.kind.isScheduler ? L("队列里没有你的作业", "No jobs in the queue") : L("空闲中 · 没有在跑的任务", "Idle · nothing running"))
                }
                .font(Theme.rounded(11))
                .foregroundStyle(Theme.tertiary)
                .frame(height: IslandLayout.emptyRow)
            }
        }
        .padding(IslandLayout.cardPad)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: IslandLayout.cardHeight(p), alignment: .top)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(LinearGradient(colors: [Color.white.opacity(0.075), Color.white.opacity(0.035)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.03)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 0.6))
        )
    }

    private var gap: some View { Spacer().frame(height: IslandLayout.sectionGap) }

    /// squeue / qstat 不存在（command not found / 未找到命令 / 退出码 127）。
    static func isMissingSqueue(_ w: String, _ host: HostConfig) -> Bool {
        guard (host.kind == .slurm && w.hasPrefix("squeue")) || (host.kind == .pbs && w.hasPrefix("qstat")) else { return false }
        let l = w.lowercased()
        return l.contains("not found") || w.contains("未找到") || l.contains("no such file") || w.contains("127")
    }

    private var header: some View {
        HStack(spacing: 7) {
            StatusDot(color: host.paused ? Theme.tertiary : Theme.color(for: snap.health), size: 6.5)
            Text(host.displayName)
                .font(Theme.rounded(13, .semibold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if host.isLocalTaskHost {
                Text("LOCAL").font(Theme.rounded(9, .bold)).foregroundStyle(Theme.cyan)
            } else { KindBadge(kind: host.kind) }
            if snap.runningCount + snap.pendingCount > 0 {
                JobCountChips(running: snap.runningCount, pending: snap.pendingCount, dimmed: host.paused)
            }
            Spacer(minLength: 6)
            HStack(spacing: 0) {
                if !host.isLocalTaskHost {
                if host.kind == .direct {
                    SmallIconButton(systemName: "eye", help: L("从高负载进程中挑选要监听的进程", "Pick a busy process to watch"), action: onPicker)
                } else if host.kind == .slurm {
                    SmallIconButton(systemName: "square.grid.3x3.fill", help: L("分区空闲资源（按需查询 sinfo）", "Free partition resources (sinfo, on demand)"), action: onPartitions)
                }
                SmallIconButton(systemName: "terminal", help: L("在终端中打开这台服务器（ssh 登录）", "Open this server in Terminal (ssh)")) {
                    SSHRunner.openShellInTerminal(host: host)
                }
                SmallIconButton(systemName: "clock.arrow.circlepath", help: L("历史记录：结束的任务、目录", "History: finished jobs and their folders"), action: onHistory)
                IntervalMenu(current: host.interval, global: globalInterval, globalAuto: globalAuto, paused: host.paused,
                             onSet: onSetInterval)
                SmallIconButton(systemName: host.paused ? "play.fill" : "pause.fill",
                                help: host.paused ? L("恢复自动刷新", "Resume auto refresh") : L("暂停自动刷新（知道这台机器没有任务时用；仍可手动刷新）", "Pause auto refresh (manual refresh still works)"),
                                tint: host.paused ? Theme.amber : Theme.tertiary, action: onTogglePause)
                SmallIconButton(systemName: host.muted ? "bell.slash.fill" : "bell.fill",
                                help: host.muted ? L("取消静音", "Unmute") : L("静音这台服务器（不弹提示、不发通知、不响铃）", "Mute this server (no pop-ups, notifications or sounds)"),
                                tint: host.muted ? Theme.amber : Theme.tertiary, action: onToggleMute)
                }
            }
            if snap.isRefreshing {
                ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 12, height: 12)
            }
            if let t = snap.lastUpdate {
                Text(Format.relative(t, now: now))
                    .font(Theme.rounded(10).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
            }
            if let l = snap.latency {
                Text("\(Int(l * 1000))ms")
                    .font(Theme.rounded(10).monospacedDigit())
                    .foregroundStyle(Theme.tertiary)
                    .help(L("本次查询耗时（含 SSH 往返）", "Query time incl. SSH round trip"))
            }
        }
    }

    private var metrics: some View {
        let m = snap.metrics
        return HStack(spacing: 16) {
            HStack(spacing: 16) {
                if host.showCPU, let cpu = m.cpuPercent {
                    MetricChip(label: "CPU", fraction: cpu / 100, valueText: "\(Int(cpu.rounded()))%",
                               help: [m.cores.map { L("\($0) 核", "\($0) cores") }, m.load1.map { String(format: L("负载 %.2f", "load %.2f"), $0) }]
                                   .compactMap { $0 }.joined(separator: " · "))
                }
                if host.showMemory, let f = m.memoryFraction {
                    MetricChip(label: L("内存", "MEM"), fraction: f,
                               valueText: "\(Format.bytes(m.memoryUsed ?? 0).dropLast())/\(Format.bytes(m.memoryTotal ?? 0))",
                               showsFractionOnClick: true)
                }
                if host.showGPU, !snap.gpus.isEmpty {
                    if snap.gpus.count <= 2 {
                        ForEach(snap.gpus) { GPUDetailChip(gpu: $0, showIndex: snap.gpus.count > 1) }
                    } else {
                        GPUCells(gpus: snap.gpus)
                    }
                }
                if IslandLayout.showsDiskColumns(host, snap) {
                    DiskColumns(disks: snap.disks)
                } else if host.showDisk, let d = snap.disks.max(by: { $0.fraction < $1.fraction }), d.fraction >= 0.8 {
                    DiskChip(disk: d, all: snap.disks)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            if !host.enabledActions.isEmpty {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array((0...host.enabledActions.count).reversed()), id: \.self) { count in
                        actionButtons(visibleCount: count)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Spacer(minLength: 0)
            }
        }
    }

    /// 从全部按钮到仅菜单逐级尝试，只折叠剩余宽度容纳不下的后续项，保留用户配置顺序。
    private func actionButtons(visibleCount: Int) -> some View {
        HStack(spacing: 4) {
            ForEach(host.enabledActions.prefix(visibleCount)) { action in
                Button { onRunAction(action) } label: {
                    HStack(spacing: 3) {
                        Image(systemName: actionIsRunning(action) ? "hourglass" : "play.fill")
                            .font(.system(size: 6, weight: .bold))
                        Text(action.name.isEmpty ? L("未命名", "Untitled") : action.name)
                            .font(Theme.rounded(8, .bold)).lineLimit(1)
                    }
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(Theme.cyan.opacity(0.14)))
                    .foregroundStyle(Theme.cyan)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).fixedSize(horizontal: true, vertical: false)
                .disabled(!action.isValid || actionIsRunning(action))
                .help(action.name + " · " + action.target.label
                    + (actionIsRunning(action) ? L(" · 运行中", " · running") : ""))
                .accessibilityLabel(action.name + " · " + action.target.label)
            }
            if host.enabledActions.count > visibleCount {
                Menu {
                    ForEach(host.enabledActions.dropFirst(visibleCount)) { action in
                        Button(action.name.isEmpty ? L("未命名", "Untitled") : action.name) { onRunAction(action) }
                            .disabled(!action.isValid || actionIsRunning(action))
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Theme.cyan).frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(L("更多 Actions", "More Actions"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var problemRow: some View {
        let (msg, isLogin): (String, Bool) = {
            switch snap.health {
            case .needsLogin(let m): return (m, true)
            case .error(let m): return (m, false)
            default: return ("", false)
            }
        }()
        return HStack(spacing: 8) {
            Image(systemName: isLogin ? "key.fill" : "wifi.exclamationmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isLogin ? Theme.amber : Theme.coral)
            Text(msg)
                .font(Theme.rounded(11.5))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(msg)
            Spacer(minLength: 6)
            if isLogin {
                if loggingIn {
                    ProgressView().controlSize(.mini).scaleEffect(0.7)
                    Text(L("等待输入…", "Waiting…")).font(Theme.rounded(10.5)).foregroundStyle(Theme.amber)
                } else {
                    PillButton(title: L("登录…", "Log In…"), tint: Theme.amber, action: onLogin)
                        .help(L("弹出密码框输入密码 / 动态口令；连接会在后台保持（\(host.keepAlive.label)）", "Enter your password / OTP in a dialog; the connection is kept for \(host.keepAlive.label)"))
                    SmallIconButton(systemName: "terminal", help: L("改用终端登录", "Log in via Terminal")) { SSHRunner.openLoginInTerminal(host: host) }
                }
            }
            PillButton(title: L("重试", "Retry"), tint: Theme.secondary, action: onRefresh)
        }
    }
}

struct PillButton: View {
    var title: String
    var tint: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.rounded(10.5, .semibold))
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(hovering ? 0.28 : 0.16)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct JobRow: View {
    var job: RemoteJob
    var kind: HostKind
    var now: Date
    var sampledAt: Date?

    /// 运行中的任务在两次采样之间本地继续计时，看起来是"活"的。
    private var liveElapsed: TimeInterval? {
        guard let e = job.elapsed else { return nil }
        if job.state == .running, let t = sampledAt { return e + max(0, now.timeIntervalSince(t)) }
        return e
    }

    private var liveFraction: Double? {
        if let p = job.progress { return min(max(p, 0), 1) }
        if let e = liveElapsed, let l = job.limit, l > 0 { return min(e / l, 1) }
        return nil
    }

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(job.name)
                        .font(Theme.rounded(12, .medium))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(job.detail.isEmpty ? job.name : job.detail)
                    if job.watched {
                        Image(systemName: "eye.fill").font(.system(size: 8.5)).foregroundStyle(Theme.mint)
                            .help(L("手动监听的进程", "Watched process"))
                    }
                    if job.array != nil {
                        Text(L("数组 #\(job.id)", "array #\(job.id)"))
                            .font(Theme.mono(9.5, .semibold))
                            .foregroundStyle(Theme.violet)
                    } else if job.source != .progressFile {
                        Text(job.source == .slurm ? "#\(job.id)" : "pid \(job.id)")
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    Text(rightText)
                        .font(Theme.rounded(10.5, .medium).monospacedDigit())
                        .foregroundStyle(job.hasRealProgress ? Theme.mint : Theme.secondary)
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    if let a = job.array {
                        ArrayBar(array: a, height: 4)
                            .help(ArrayBar.legend(a))
                        ArrayStatusText(array: a)
                            .frame(width: 210, alignment: .trailing)
                            .help(ArrayBar.legend(a))
                    } else if job.state == .pending {
                        let r = PendingReason.explain(job.reason)
                        HStack(spacing: 4) {
                            if r?.needsAction == true {
                                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5))
                            }
                            Text(pendingText(r))
                        }
                        .font(Theme.rounded(10, r?.needsAction == true ? .semibold : .regular))
                        .foregroundStyle(r?.needsAction == true ? Theme.coral.opacity(0.9) : Theme.amber.opacity(0.8))
                        .lineLimit(1)
                        .help(r?.long ?? job.detail)
                        Spacer(minLength: 0)
                    } else {
                        SlimBar(fraction: liveFraction,
                                fill: job.hasRealProgress ? AnyShapeStyle(Theme.progress)
                                    : AnyShapeStyle(Theme.timeProgress.opacity(0.7)),
                                height: 4)
                        Text(detailText)
                            .font(Theme.rounded(10))
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: 210, alignment: .trailing)
                    }
                }
            }
        }
    }

    private var icon: some View {
        let color = Theme.color(for: job.state)
        let symbol: String = {
            switch job.state {
            case .pending: return "hourglass"
            case .completing: return "arrow.down.to.line"
            case .completed: return "checkmark"
            case .failed, .timeout: return "xmark"
            case .cancelled: return "minus"
            case .other: return "questionmark"
            case .running:
                if job.array != nil { return "square.stack.3d.up.fill" }
                if job.app != nil { return "atom" }
                switch job.source {
                case .slurm: return "bolt.fill"
                case .process: return "terminal.fill"
                case .progressFile: return "chart.bar.fill"
                }
            }
        }()
        return ZStack {
            Circle().fill(color.opacity(0.15))
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(color)
        }
        .frame(width: 22, height: 22)
    }

    private func pendingText(_ r: PendingReason?) -> String {
        guard let r else { return job.detail.isEmpty ? L("等待调度", "Waiting") : job.detail }
        // detail 形如 "(Priority) · a100"：保留分区
        let partition = job.detail.components(separatedBy: " · ").last.flatMap { $0.hasPrefix("(") ? nil : $0 }
        return ([r.short, partition].compactMap { $0 }).joined(separator: " · ")
    }

    private var rightText: String {
        if let a = job.array {
            return L("完成 \(a.done + a.failed)/\(max(a.total, 1))", "\(a.done + a.failed)/\(max(a.total, 1)) done")
        }
        if job.state == .pending {
            return job.limit.map { L("上限 ", "limit ") + Format.duration($0) } ?? job.state.label
        }
        if let p = job.progress {
            var s = Format.percent(p)
            if let eta = job.eta {
                s += L(" · 约剩 ", " · ~") + Format.shortDuration(eta)
            } else if job.app != nil {
                // 计算软件：还没有两次采样，暂时不估算
            } else if let e = liveElapsed, p > 0.01, p < 1 {
                s += L(" · 约剩 ", " · ~") + Format.shortDuration(e * (1 - p) / p)
            }
            return s
        }
        if let e = liveElapsed {
            if let l = job.limit { return Format.duration(e) + " / " + Format.duration(l) }
            return Format.duration(e)
        }
        return job.state.label
    }

    private var detailText: String {
        if let m = job.message, !m.isEmpty { return m }
        if job.source == .process {
            var parts: [String] = []
            if let g = job.gpuMemoryMB { parts.append(L("显存 ", "VRAM ") + Format.bytes(g * 1_048_576)) }
            if let c = job.cpuPercent { parts.append("CPU \(Int(c))%") }
            if let m = job.memoryBytes { parts.append(L("内存 ", "MEM ") + Format.bytes(m)) }
            return parts.joined(separator: " · ")
        }
        return job.detail
    }
}

/// 可点击的任务行：悬停高亮，点击查看详情。
struct JobRowButton: View {
    var job: RemoteJob
    var kind: HostKind
    var now: Date
    var sampledAt: Date?
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            JobRow(job: job, kind: kind, now: now, sampledAt: sampledAt)
                .padding(.horizontal, 6)
                .frame(maxHeight: .infinity)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0)))
                .overlay(alignment: .trailing) {
                    if hovering {
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.tertiary).padding(.trailing, -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hovering = $0 }
        .help(L("点击查看详情和日志 · 右键复制", "Click for details & log · right-click to copy"))
        .contextMenu {
            Button(L("查看详情和日志", "Details & Log"), action: action)
            if job.source != .progressFile {
                Button(job.source == .process ? L("复制 PID", "Copy PID") : L("复制作业号", "Copy Job ID")) { copy(job.id) }
            }
            Button(L("复制名称", "Copy Name")) { copy(job.name) }
            if job.source == .process, !job.detail.isEmpty {
                Button(L("复制完整命令", "Copy Full Command")) { copy(job.detail) }
            }
        }
    }
}

private func copy(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct DiskChip: View {
    var disk: DiskStat
    var all: [DiskStat]

    var body: some View {
        let c = Theme.load(disk.fraction)
        HStack(spacing: 4) {
            Image(systemName: "internaldrive.fill").font(.system(size: 9))
            Text(Format.percent(disk.fraction)).font(Theme.rounded(10.5, .semibold).monospacedDigit())
        }
        .foregroundStyle(c)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill(c.opacity(0.14)))
        .help(all.map { L("\($0.mount)  已用 \(Format.percent($0.fraction))，剩余 \(Format.bytes(($0.totalKB - $0.usedKB) * 1024))", "\($0.mount)  \(Format.percent($0.fraction)) used, \(Format.bytes(($0.totalKB - $0.usedKB) * 1024)) free") }
            .joined(separator: "\n"))
    }
}

/// 卡片上的轮询间隔菜单。
struct IntervalMenu: View {
    var current: Int?
    var global: Int
    var globalAuto: Bool
    var paused: Bool
    var onSet: (Int?) -> Void

    static let presets = [15, 30, 60, 120, 300, 600]

    var body: some View {
        if IslandPreview.active { menuLabel } else { menu }
    }

    private var menu: some View {
        Menu {
            Button { onSet(nil) } label: {
                Label(L("跟随全局", "Global") + "（" + (globalAuto ? IntervalPicker.label(global) : L("仅手动", "manual")) + "）",
                      systemImage: current == nil ? "checkmark" : "")
            }
            Divider()
            ForEach(Self.presets, id: \.self) { s in
                Button { onSet(s) } label: {
                    Label(L("每 \(IntervalPicker.label(s))", "Every \(IntervalPicker.label(s))"), systemImage: current == s ? "checkmark" : "")
                }
            }
        } label: { menuLabel }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("这台服务器的轮询间隔", "Refresh interval for this server"))
    }

    private var menuLabel: some View {
        Text(label)
            .font(Theme.rounded(9.5, .semibold).monospacedDigit())
            .foregroundStyle(paused ? Theme.tertiary.opacity(0.6) : Theme.tertiary)
            .padding(.horizontal, 5).frame(height: 18)
            .background(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .fixedSize()
    }

    private var label: String {
        if paused { return L("暂停", "paused") }
        let s = current ?? global
        if current == nil && !globalAuto { return L("手动", "manual") }
        return s < 60 ? "\(s)s" : (s % 60 == 0 ? "\(s / 60)m" : "\(s)s")
    }
}

/// 展开面板底部：合并显示的空闲机器，点击临时展开成完整卡片。
struct IdleHostsRow: View {
    var hosts: [(HostConfig, HostSnapshot)]
    var expanded: Bool
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 10))
                    .foregroundStyle(Theme.tertiary)
                Text(L("\(hosts.count) 台空闲", "\(hosts.count) idle"))
                    .font(Theme.rounded(11, .semibold))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize()
                HStack(spacing: 10) {
                    ForEach(hosts, id: \.0.id) { host, snap in
                        HStack(spacing: 4) {
                            if host.paused {
                                Image(systemName: "pause.fill").font(.system(size: 7)).foregroundStyle(Theme.tertiary)
                            } else {
                                StatusDot(color: Theme.color(for: snap.health), size: 5)
                            }
                            Text(host.displayName).lineLimit(1)
                        }
                        .help(summary(host, snap))
                    }
                }
                .font(Theme.rounded(11))
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
                Spacer(minLength: 6)
                HStack(spacing: 3) {
                    Text(expanded ? L("收起", "Hide") : L("展开", "Show"))
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .bold))
                }
                .font(Theme.rounded(10, .medium))
                .foregroundStyle(Theme.cyan.opacity(hovering ? 1 : 0.8))
                .fixedSize()
            }
            .padding(.horizontal, IslandLayout.cardPad)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.07 : 0.04))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 0.6))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L("没有任务的机器合并在这里；可以在 设置 → 通用 里关闭", "Servers with no jobs are grouped here; turn off in Settings → General"))
    }

    private func summary(_ host: HostConfig, _ snap: HostSnapshot) -> String {
        if host.paused { return L("\(host.displayName) · 自动刷新已暂停", "\(host.displayName) · auto refresh paused") }
        let m = snap.metrics
        var parts = [host.displayName]
        if let c = m.cpuPercent { parts.append("CPU \(Int(c.rounded()))%") }
        if let f = m.memoryFraction { parts.append(L("内存 ", "MEM ") + Format.percent(f)) }
        if !snap.gpus.isEmpty {
            let busy = snap.gpus.filter { $0.utilization >= 10 }.count
            parts.append("GPU \(busy)/\(snap.gpus.count)" + L(" 在用", " busy"))
        }
        return parts.joined(separator: " · ")
    }
}
