import AppKit
import Foundation

/// 负责按间隔轮询每台服务器、合并结果、识别"任务完成 / 失败 / 开始"等事件。
@MainActor
final class MonitorEngine: ObservableObject {
    @Published private(set) var snapshots: [UUID: HostSnapshot] = [:]
    @Published var currentEvent: IslandEvent?

    let store: ConfigStore
    let demo: Bool

    private var loops: [UUID: Task<Void, Never>] = [:]
    private var runningConfig: [UUID: HostConfig] = [:]
    private var cpuSamples: [UUID: Parsers.CPUSample] = [:]
    private var failures: [UUID: Int] = [:]
    private var isAsleep = false { didSet { asleepSince = isAsleep ? Date() : nil } }
    private var asleepSince: Date?
    private var observers: [NSObjectProtocol] = []
    private var eventQueue: [IslandEvent] = []
    private var eventDismissTask: Task<Void, Never>?
    private var diskAlerted: [UUID: Set<String>] = [:]
    let history: HistoryStore
    /// 数组作业的累计进度（key: 主机|主编号）。
    struct ArrayTrack {
        var done = 0, failed = 0, total = 0
        var initialized = false
        var accurate = false
        var alertedFailure = false
    }
    var arrayTracks: [String: ArrayTrack] = [:]
    struct AppRateState { var current: Double; var at: Date; var rate: Double? }
    var appRates: [String: AppRateState] = [:]
    /// 详情页曲线的增量缓存（见 AppCurves）。
    var curveCaches: [String: CurveCache] = [:]
    /// 目录过滤用：每台服务器上各任务的工作目录。
    struct WorkdirCache { var home: String?; var dirs: [String: String] = [:] }
    var workdirCache: [UUID: WorkdirCache] = [:]
    var partitionCache: [UUID: (stats: [PartitionStat], at: Date)] = [:]
    /// 正在弹窗登录的主机。
    @Published var loggingIn: Set<UUID> = []
    /// 上次后台自动重新登录的时间（限频）。
    var lastAutoLogin: [UUID: Date] = [:]
    /// 运行中各机器的跳板机链（跳板机的连接设置变了，经它跳转的机器也要重连）。
    private var runningChain: [UUID: [HostConfig]] = [:]
    func arrayKey(_ host: UUID, _ base: String) -> String { host.uuidString + "|" + base }

    /// 不支持 sacct 历史查询的主机（本次运行内不再尝试）。
    var sacctUnsupported: Set<UUID> = []
    var onEvent: ((IslandEvent) -> Void)?

    init(store: ConfigStore, demo: Bool = false) {
        self.store = store
        self.demo = demo
        history = HistoryStore(persist: store.persist && !demo)
    }

    // MARK: - 生命周期

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isAsleep = true; DebugLog.log("系统即将睡眠") }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleWake() }
        })
        sync()
    }

    private var syncWork: DispatchWorkItem?

    private func handleWake() {
        isAsleep = false
        DebugLog.log("系统已唤醒")
        // 网络恢复需要一点时间。
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            for host in self.store.settings.hosts where host.enabled && self.autoPolls(host) { self.restart(host, pollNow: true) }
        }
    }

    /// 配置变化后调用（带防抖，避免在设置里打字时反复连接）：只重启有改动的主机。
    func sync() {
        syncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.syncNow() }
        syncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (loops.isEmpty ? 0 : 1.2), execute: work)
    }

    private var lastAutoRefresh: Bool?
    private var lastDefaultInterval: Int?

    /// 这台机器是否自动轮询（全局"仅手动刷新"或单台"暂停"时为 false）。
    func autoPolls(_ host: HostConfig) -> Bool {
        store.settings.autoRefresh && !host.paused
    }

    private func syncNow() {
        let hosts = store.settings.hosts.filter(\.enabled)
        let ids = Set(hosts.map(\.id))
        for (id, task) in loops where !ids.contains(id) {
            task.cancel()
            loops[id] = nil
            runningConfig[id] = nil
            snapshots[id] = nil
        }
        // 全局开关 / 默认间隔变化：重新安排所有机器（打开自动刷新时立刻刷一次）。
        let globalChanged = lastAutoRefresh != nil
            && (lastAutoRefresh != store.settings.autoRefresh || lastDefaultInterval != store.settings.defaultInterval)
        let turnedOn = lastAutoRefresh == false && store.settings.autoRefresh
        lastAutoRefresh = store.settings.autoRefresh
        lastDefaultInterval = store.settings.defaultInterval

        for host in hosts {
            // 首次启动：暂停的机器完全不连接，直到用户手动刷新。
            guard let old = runningConfig[host.id] else { restart(host, pollNow: !host.paused); continue }
            // 只改了名称 / 静音 / 取消权限时不需要重新连接。
            var a = old, b = host
            a.displayName = ""; b.displayName = ""
            a.muted = false; b.muted = false; a.allowCancel = false; b.allowCancel = false
            a.paused = false; b.paused = false
            a.rememberPassword = false; b.rememberPassword = false
            let chain = SSHHosts.chain(host, in: Dictionary(store.settings.hosts.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x }))
            let chainChanged = runningChain[host.id].map { connectionKey($0) != connectionKey(chain) } ?? false
            runningChain[host.id] = chain
            if a != b || chainChanged {
                restart(host, pollNow: true)
            } else if old.paused != host.paused {
                // 暂停：停止循环；恢复：立刻刷新一次并继续。
                restart(host, pollNow: !host.paused)
            } else if globalChanged {
                restart(host, pollNow: turnedOn)
            } else {
                runningConfig[host.id] = host
            }
        }
    }

    /// 跳板机链里影响连接的字段。
    private func connectionKey(_ chain: [HostConfig]) -> [String] {
        chain.map { [$0.id.uuidString, $0.alias, $0.hostName, $0.user, "\($0.port ?? 0)", $0.identityFile,
                     $0.jumpHostID?.uuidString ?? "", $0.auth.rawValue].joined(separator: "|") }
    }

    /// 刷新全部（不包括已暂停的机器；暂停的机器只能在它自己的卡片上手动刷新）。
    func refreshAll() {
        for host in store.settings.hosts where host.enabled && !host.paused { restart(host, pollNow: true) }
    }

    /// 手动刷新（暂停或"仅手动刷新"时也可以用）。
    func refresh(_ id: UUID) {
        if let host = store.host(id), host.enabled { restart(host, pollNow: true) }
    }

    func setPaused(_ id: UUID, _ paused: Bool) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == id }) else { return }
        store.settings.hosts[i].paused = paused
        DebugLog.log("[\(store.settings.hosts[i].displayName)] \(paused ? "暂停" : "恢复")自动刷新")
        syncNow()
    }

    func setHostInterval(_ id: UUID, _ seconds: Int?) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == id }) else { return }
        store.settings.hosts[i].interval = seconds
        syncNow()
    }

    func setGlobalInterval(_ seconds: Int) {
        store.settings.defaultInterval = seconds
        store.settings.autoRefresh = true
        syncNow()
    }

    func setAutoRefresh(_ on: Bool) {
        store.settings.autoRefresh = on
        DebugLog.log(on ? "开启自动刷新" : "切换为仅手动刷新")
        syncNow()
    }

    private func restart(_ host: HostConfig, pollNow: Bool) {
        loops[host.id]?.cancel()
        loops[host.id] = nil
        runningConfig[host.id] = host
        failures[host.id] = 0
        if snapshots[host.id] == nil { snapshots[host.id] = HostSnapshot() }
        let id = host.id
        let auto = autoPolls(host)
        guard pollNow || auto else {
            DebugLog.log("[\(host.displayName)] " + (host.paused ? "已暂停自动刷新" : "全局为仅手动刷新"))
            return
        }
        DebugLog.log("[\(host.displayName)] " + (auto ? "启动轮询（间隔 \(store.interval(for: host))s）" : "手动刷新一次"))
        loops[id] = Task { [weak self] in
            var first = true
            while !Task.isCancelled {
                guard let self else { return }
                if !first || pollNow {
                    // 保险：如果错过了唤醒通知，睡眠标记最多保持 2 分钟。
                    if self.isAsleep, let t = self.asleepSince, Date().timeIntervalSince(t) > 120 {
                        DebugLog.log("睡眠标记超时，自动恢复轮询")
                        self.isAsleep = false
                    }
                    if !self.isAsleep {
                        await self.pollOnce(id)
                    } else {
                        DebugLog.log("[\(self.runningConfig[id]?.displayName ?? "?")] 系统睡眠中，跳过本次轮询")
                    }
                }
                first = false
                // 暂停 / 仅手动刷新：刷完这一次就停。
                guard let h = self.runningConfig[id], self.autoPolls(h) else { return }
                let delay = self.nextDelay(for: id)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// 连续失败时指数退避（60s → 2m → 4m … 最多 15m），避免触发服务器的 fail2ban。
    private func nextDelay(for id: UUID) -> Double {
        guard let host = runningConfig[id] else { return 60 }
        if demo && DemoData.isDemoHost(host) { return 2 }
        let base = Double(store.interval(for: host))
        let n = failures[id] ?? 0
        guard n > 0 else { return base }
        return min(base * pow(2, Double(n - 1)), 900)
    }

    // MARK: - 轮询

    private func pollOnce(_ id: UUID) async {
        guard let host = runningConfig[id] else { return }
        if demo && DemoData.isDemoHost(host) {
            applyDemo(host)
            return
        }
        // 渲染预览图时不连接任何真实服务器（虚构的主机用 setPreviewSnapshot 给定状态）。
        if IslandPreview.active { return }
        snapshots[id]?.isRefreshing = true
        let result = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                         script: RemoteScript.build(for: host))
        guard !Task.isCancelled else { snapshots[id]?.isRefreshing = false; return }

        var snap = snapshots[id] ?? HostSnapshot()
        snap.isRefreshing = false

        if let problem = SSHRunner.classify(result, host: host) {
            failures[id, default: 0] += 1
            snap.health = problem
            snapshots[id] = snap
            if case .needsLogin = problem {
                // 先登录远端的跳板机，再登录自己（都只在记住了密码时才会自动进行）
                for h in SSHHosts.jumpChain(host).reversed() + [host] { autoRelogin(h) }
            }
            DebugLog.log("[\(host.displayName)] 连接失败（第 \(failures[id] ?? 0) 次）：\(problem)  stderr=\(result.stderr.prefix(200))")
            return
        }

        let parsed = RemoteScript.parse(result.stdout)
        guard parsed.sawBegin else {
            failures[id, default: 0] += 1
            let err = (result.stderr + result.stdout).trimmingCharacters(in: .whitespacesAndNewlines)
            snap.health = .error(err.isEmpty ? L("远端 shell 没有输出（检查“远端 shell”设置）", "No output from the remote shell (check Remote Shell)") : String(err.prefix(120)))
            snapshots[id] = snap
            return
        }

        failures[id] = 0
        let previous = snap
        snap = build(host: host, parsed: parsed, previous: previous)
        snap.latency = result.duration
        snap.lastUpdate = Date()
        snap.health = .ok
        snapshots[id] = snap
        DebugLog.log("[\(host.displayName)] 轮询成功 \(String(format: "%.2fs", result.duration))：运行 \(snap.runningCount) 排队 \(snap.pendingCount)"
                     + (snap.jobs.isEmpty ? "" : " · " + snap.jobs.prefix(8).map { "\($0.id)(\($0.name.prefix(24)),\(Int($0.elapsed ?? -1))s)" }.joined(separator: " ")))
        await detectEvents(host: host, old: previous, new: snap)
        // 任务列表读全了才更新"上次看到的任务"（squeue 出错时列表是空的，不能当成全部结束）
        if host.watchJobs, !demo, jobsListed(host: host, parsed: parsed) {
            if previous.lastUpdate == nil { await recordEndedWhileAway(host: host, now: snap) }
            history.setActive(id, snap.jobs)
        }
        await initializeArrays(host: host)
    }

    /// 这次采样的任务列表是否完整（作业队列 / 进程列表的命令都成功了）。
    private func jobsListed(host: HostConfig, parsed: RemoteScript.Parsed) -> Bool {
        var names: [String] = []
        switch host.kind {
        case .slurm: names = ["squeue"] + (host.slurmAlsoProcesses ? ["procs"] : [])
        case .pbs: names = ["qstat"] + (host.slurmAlsoProcesses ? ["procs"] : [])
        case .direct: names = ["procs"]
        }
        return names.allSatisfy { parsed.sections[$0]?.exitCode == 0 }
    }

    /// 启动后第一次连上服务器：上次退出时还在运行 / 排队、现在不在了的任务，补记到历史里（不弹提醒）。
    /// Slurm 作业用 sacct 查结果；查不到时记成"已结束"（不知道成功与否），结束时间按上次看到它的时间。
    private func recordEndedWhileAway(host: HostConfig, now: HostSnapshot) async {
        let current = Set(now.jobs.map(\.id))
        let gone = history.activeJobs(for: host.id).filter { !current.contains($0.id) }
        guard !gone.isEmpty else { return }
        var finals: [String: (state: JobState, raw: String, elapsed: TimeInterval?, exit: String)] = [:]
        let slurmIDs = gone.filter(\.slurm).map(\.id).filter { !$0.contains("[") }
        if !slurmIDs.isEmpty, !sacctUnsupported.contains(host.id) {
            let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                        script: RemoteScript.sacctScript(for: host, jobIDs: slurmIDs), timeout: 20)
            if let sec = RemoteScript.parse(r.stdout).sections["sacct"] { finals = Parsers.sacct(sec.lines) }
        }
        for j in gone.reversed() {
            let f = finals[j.id]
            // 数组的主编号在 sacct 里没有单独一行，按元素统计
            let elems = finals.filter { $0.key.hasPrefix(j.id + "_") }
            var state = f.map { $0.state.isActive ? HistoryEntry.endedUnknown : $0.raw } ?? HistoryEntry.endedUnknown
            var note = L("ServerIsland 未运行时结束", "ended while ServerIsland wasn't running")
            if f == nil, !elems.isEmpty {
                let bad = elems.values.filter { [.failed, .timeout, .cancelled].contains($0.state) }.count
                state = bad > 0 ? "FAILED" : "COMPLETED"
                note = L("数组 ", "array ") + "\(elems.count - bad)✓ \(bad)✗ · " + note
            }
            history.record(host.id, HistoryEntry(id: j.id, name: j.name, state: state, elapsed: f?.elapsed ?? j.elapsed,
                                                 endedAt: j.seenAt, exitCode: f?.exit, note: note, dir: j.dir))
        }
        DebugLog.log("[\(host.displayName)] 补记 ServerIsland 未运行时结束的任务：\(gone.map(\.id).joined(separator: " "))")
    }

    private func build(host: HostConfig, parsed: RemoteScript.Parsed, previous: HostSnapshot) -> HostSnapshot {
        var snap = HostSnapshot()
        var warnings: [String] = []

        func check(_ name: String, label: String) -> RemoteScript.Section? {
            guard let sec = parsed.sections[name] else { return nil }
            if let rc = sec.exitCode, rc != 0 {
                let msg = sec.lines.last { !$0.isEmpty } ?? L("退出码 \(rc)", "exit code \(rc)")
                warnings.append("\(label)：\(msg.prefix(90))")
            }
            return sec
        }

        if let sec = check("cpu", label: "CPU") {
            let r = Parsers.cpu(sec.lines)
            snap.metrics.cores = r.cores
            snap.metrics.load1 = r.load1
            if let s = r.sample {
                if let prev = cpuSamples[host.id], s.total > prev.total {
                    snap.metrics.cpuPercent = (s.busy - prev.busy) / (s.total - prev.total) * 100
                } else if let l = r.load1, let c = r.cores, c > 0 {
                    snap.metrics.cpuPercent = min(l / Double(c) * 100, 100)
                }
                cpuSamples[host.id] = s
            }
        }
        if let sec = check("mem", label: L("内存", "Memory")), let m = Parsers.memory(sec.lines) {
            snap.metrics.memoryUsed = m.used
            snap.metrics.memoryTotal = m.total
        }
        if host.showGPU, let sec = check("gpu", label: "GPU"), !sec.notAvailable {
            snap.gpus = Parsers.gpus(sec.lines)
        }

        let apps: [String: AppProgress] = parsed.sections["apps"].map { AppDetectors.parse($0.lines) } ?? [:]
        var jobs: [RemoteJob] = []
        switch host.kind {
        case .slurm, .pbs:
            // PBS 的 qstat 输出在远端已经转换成 squeue 的格式（见 RemoteScript.pbsFunction）。
            let queue = host.kind == .pbs ? "qstat" : "squeue"
            if let sec = check(queue, label: queue) {
                jobs = Parsers.squeue(sec.exitCode == 0 ? sec.lines : [])
            }
            // 单机 Slurm：同时列出不经过 Slurm 直接运行的进程（属于作业的进程已由作业行显示）。
            if host.slurmAlsoProcesses, let sec = check("procs", label: L("进程", "Processes")) {
                var gpuMem: [String: Double] = [:]
                if let g = parsed.sections["gpuapps"], !g.notAvailable { gpuMem = Parsers.gpuApps(g.lines) }
                let inJobs = Set((parsed.sections["slurmpids"]?.lines ?? []).map { $0.trimmingCharacters(in: .whitespaces) })
                let jobIDs = Set(jobs.map(\.id))
                let procs = Parsers.processes(sec.lines, filter: host.processFilter, exclude: host.processExclude, gpuMem: gpuMem,
                                              alwaysInclude: Set(apps.keys).subtracting(jobIDs))
                jobs += procs.filter { !inJobs.contains($0.id) }
            }
        case .direct:
            if let sec = check("procs", label: L("进程", "Processes")) {
                var gpuMem: [String: Double] = [:]
                if let apps = parsed.sections["gpuapps"], !apps.notAvailable { gpuMem = Parsers.gpuApps(apps.lines) }
                jobs = Parsers.processes(sec.lines, filter: host.processFilter, exclude: host.processExclude, gpuMem: gpuMem,
                                         alwaysInclude: Set(apps.keys))
            }
        }

        // 手动监听的进程：不受过滤规则影响。
        if host.kind == .direct, !host.watched.isEmpty, let sec = parsed.sections["watch"] {
            let all = Parsers.processes(sec.lines, filter: "", gpuMem: [:])
            for w in host.watched {
                guard var p = all.first(where: { $0.id == w.pid }) else { continue }
                // PID 被复用（启动时间对不上）就当作原进程已经结束。
                if let started = w.startedAt, let e = p.elapsed,
                   abs(Date().addingTimeInterval(-e).timeIntervalSince(started)) > 30 { continue }
                if let i = jobs.firstIndex(where: { $0.id == w.pid }) {
                    jobs[i].watched = true
                } else {
                    p.watched = true
                    p.name = w.name.isEmpty ? p.name : w.name
                    jobs.append(p)
                }
            }
        }
        // 工作目录：记到每个任务上（写进历史记录）；设了"只看这些目录"时再按目录过滤（手动监听的进程不受影响）。
        if host.watchJobs {
            jobs = applyWorkdirs(host: host, jobs: jobs, section: parsed.sections["workdirs"])
        }
        if host.showDisk, let sec = parsed.sections["disk"], sec.exitCode == 0 {
            snap.disks = Parsers.disks(sec.lines)
        }

        if let sec = parsed.sections["progress"] {
            let staleCutoff = Date().addingTimeInterval(-36 * 3600)
            for entry in Parsers.progress(sec.lines) {
                if let u = entry.updated, u < staleCutoff { continue }
                if let jid = entry.jobID, let i = jobs.firstIndex(where: { $0.id == jid }) {
                    jobs[i].progress = entry.progress
                    jobs[i].message = entry.message
                    if jobs[i].source == .slurm, entry.name != entry.id { jobs[i].name = entry.name }
                } else {
                    var job = RemoteJob(id: "file:" + entry.id, name: entry.name,
                                        state: entry.failed ? .failed : (entry.done ? .completed : .running),
                                        source: .progressFile)
                    job.progress = entry.done ? 1 : entry.progress
                    job.message = entry.message
                    if let u = entry.updated { job.detail = L("更新于 ", "updated ") + Format.relative(u) }
                    jobs.append(job)
                }
            }
        }

        // 计算软件进度（NEP / GPUMD）：合并到对应任务，用两次采样估算速度和剩余时间。
        if !apps.isEmpty {
            for i in jobs.indices {
                guard var app = apps[jobs[i].id] else { continue }
                applyAppRate(host: host, jobID: jobs[i].id, &app)
                jobs[i].app = app
                if let f = app.fraction { jobs[i].progress = f }
                jobs[i].eta = app.eta
                var msg = app.title + " · " + app.summary
                if let u = app.updatedAt, !app.finished {
                    let quiet = Date().timeIntervalSince(u)
                    if quiet > max(600, Double(store.interval(for: host)) * 5) {
                        msg = L("⚠︎ \(Format.shortDuration(quiet)) 没有新输出 · ", "⚠︎ no output for \(Format.shortDuration(quiet)) · ") + msg
                    }
                }
                jobs[i].message = msg
            }
        }
        if host.kind.isScheduler {
            jobs = Parsers.groupArrays(jobs)
            for i in jobs.indices { if jobs[i].array != nil { applyTrack(host: host.id, &jobs[i]) } }
        }
        snap.jobs = jobs.sorted { order($0) < order($1) }
        snap.warnings = Array(warnings.prefix(2))
        return snap
    }

    /// 工作目录和目录过滤。工作目录按任务号缓存：某一次没查到（网络抖动、刚提交的作业）时沿用上次的结果，
    /// 不会让任务忽隐忽现、误发"已结束"的提醒。设了目录过滤时，查不到目录的任务不显示。
    private func applyWorkdirs(host: HostConfig, jobs: [RemoteJob], section: RemoteScript.Section?) -> [RemoteJob] {
        var cache = workdirCache[host.id] ?? WorkdirCache()
        if let section {
            let r = Parsers.workdirs(section.lines)
            if let h = r.home { cache.home = h }
            for (k, v) in r.dirs { cache.dirs[k] = v }
        }
        // 只保留当前还在列表里的，缓存不会越积越大。
        let ids = Set(jobs.map(\.id))
        cache.dirs = cache.dirs.filter { ids.contains($0.key) }
        workdirCache[host.id] = cache
        var jobs = jobs
        for i in jobs.indices where jobs[i].workdir == nil { jobs[i].workdir = cache.dirs[jobs[i].id] }
        guard !host.pathPrefixes.isEmpty else { return jobs }
        return jobs.filter { job in
            if job.source == .progressFile || job.watched { return true }
            guard let dir = cache.dirs[job.id] else { return false }
            return Parsers.pathMatches(dir, prefixes: host.pathPrefixes, home: cache.home)
        }
    }

    /// 每秒推进量：与上次采样比较，指数平滑；数字倒退（续训 / 重跑）时重置。
    private func applyAppRate(host: HostConfig, jobID: String, _ app: inout AppProgress) {
        let key = host.id.uuidString + "|" + jobID + "|" + app.dir
        guard let cur = app.current else { return }
        let now = Date()
        if var st = appRates[key] {
            if cur < st.current {
                st = AppRateState(current: cur, at: now, rate: nil)
            } else if cur > st.current, now.timeIntervalSince(st.at) >= 2 {
                let r = (cur - st.current) / now.timeIntervalSince(st.at)
                st.rate = st.rate.map { $0 * 0.5 + r * 0.5 } ?? r
                st.current = cur
                st.at = now
            }
            appRates[key] = st
            app.rate = st.rate
        } else {
            appRates[key] = AppRateState(current: cur, at: now, rate: nil)
        }
    }

    func applyTrack(host: UUID, _ job: inout RemoteJob) {
        guard var a = job.array else { return }
        let key = arrayKey(host, a.baseID)
        var t = arrayTracks[key] ?? ArrayTrack()
        t.total = max(t.total, t.done + t.failed + a.running.count + a.pending)
        arrayTracks[key] = t
        a.done = t.done; a.failed = t.failed; a.total = t.total; a.accurate = t.accurate
        job.array = a
        job.detail = L("运行 \(a.running.count) · 排队 \(a.pending)", "\(a.running.count) running · \(a.pending) pending") + (a.failed > 0 ? L(" · 失败 \(a.failed)", " · \(a.failed) failed") : "")
    }

    /// 第一次看到某个数组时，用 sacct 补上 ServerIsland 启动前就结束了的元素。
    private func initializeArrays(host: HostConfig) async {
        guard let snap = snapshots[host.id] else { return }
        let bases = snap.jobs.compactMap(\.array).map(\.baseID)
            .filter { !(arrayTracks[arrayKey(host.id, $0)]?.initialized ?? false) }
        guard !bases.isEmpty else { return }
        for base in bases { arrayTracks[arrayKey(host.id, base), default: ArrayTrack()].initialized = true }
        guard !sacctUnsupported.contains(host.id) else { return }
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: RemoteScript.sacctScript(for: host, jobIDs: bases), timeout: 25)
        guard let sec = RemoteScript.parse(r.stdout).sections["sacct"], sec.exitCode == 0 else { return }
        let finals = Parsers.sacct(sec.lines)
        for base in bases {
            let key = arrayKey(host.id, base)
            var t = arrayTracks[key] ?? ArrayTrack()
            let mine = finals.filter { $0.key.hasPrefix(base + "_") && !$0.key.contains("[") }
            t.done = mine.values.filter { $0.state == .completed }.count
            t.failed = mine.values.filter { [.failed, .timeout, .cancelled].contains($0.state) }.count
            t.accurate = true
            arrayTracks[key] = t
        }
        refreshTracks(host.id)
    }

    /// 计数变化后，把最新的累计值写回当前快照。
    private func refreshTracks(_ id: UUID) {
        guard var snap = snapshots[id] else { return }
        for i in snap.jobs.indices where snap.jobs[i].array != nil { applyTrack(host: id, &snap.jobs[i]) }
        snapshots[id] = snap
    }

    private func order(_ j: RemoteJob) -> Int {
        if j.watched && j.state == .running { return -1 }
        switch j.state {
        case .running, .completing: return 0
        case .pending: return 1
        default: return 2
        }
    }

    // MARK: - 事件识别

    private func detectEvents(host: HostConfig, old: HostSnapshot, new: HostSnapshot) async {
        // 第一次成功采样时不产生事件。
        guard old.lastUpdate != nil else { return }
        var batch: [IslandEvent] = []
        defer { flush(batch, host: host) }
        checkDisks(host: host, new: new, batch: &batch)
        let newByID = Dictionary(new.jobs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        var vanished: [RemoteJob] = []
        var arrayElementsDone: [(base: String, job: RemoteJob)] = []
        var arraysFinished: [RemoteJob] = []
        for job in old.jobs where job.state.isActive {
            if let a = job.array {
                // 数组：按元素比较；排队范围的编号变化（123_[7-99] -> 123_[8-99]）不算"消失"。
                if let now = newByID[job.id], let na = now.array {
                    let still = Set(na.running.map(\.id))
                    for e in a.running where !still.contains(e.id) { arrayElementsDone.append((a.baseID, e)) }
                } else {
                    for e in a.running { arrayElementsDone.append((a.baseID, e)) }
                    arraysFinished.append(job)
                }
                continue
            }
            if let now = newByID[job.id] {
                if job.state == .pending && now.state == .running {
                    batch.append(.init(kind: .started, title: L("\(now.name) 开始运行", "\(now.name) started"), subtitle: now.detail, hostName: host.displayName, hostID: host.id))
                } else if job.source == .progressFile, now.state == .completed {
                    batch.append(.init(kind: .finished, title: L("\(now.name) 已完成", "\(now.name) finished"), subtitle: now.message ?? "", hostName: host.displayName, hostID: host.id))
                } else if job.source == .progressFile, now.state == .failed {
                    batch.append(.init(kind: .failed, title: L("\(now.name) 失败", "\(now.name) failed"), subtitle: now.message ?? "", hostName: host.displayName, hostID: host.id))
                }
            } else if job.source == .slurm || job.watched || (job.elapsed ?? 0) >= 30 {
                // 很短的进程（运行不到 30 秒）来去很正常，不打扰。
                vanished.append(job)
                DebugLog.log("[\(host.displayName)] 任务结束：\(job.id) \(job.name)")
            } else {
                DebugLog.log("[\(host.displayName)] 忽略短进程结束：\(job.id) \(job.name)（\(Int(job.elapsed ?? 0))s）")
            }
        }
        if !arrayElementsDone.isEmpty || !arraysFinished.isEmpty {
            await handleArrays(host: host, elements: arrayElementsDone, finished: arraysFinished, batch: &batch)
        }
        guard !vanished.isEmpty else { return }

        let slurmJobs = vanished.filter { $0.source == .slurm }
        var finals: [String: (state: JobState, raw: String, elapsed: TimeInterval?, exit: String)] = [:]
        if !slurmJobs.isEmpty {
            // 只在作业从队列中消失时调用一次 sacct（sacct 查数据库，比 squeue 更重）。
            let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                        script: RemoteScript.sacctScript(for: host, jobIDs: slurmJobs.map(\.id)), timeout: 20)
            if let sec = RemoteScript.parse(r.stdout).sections["sacct"] {
                finals = Parsers.sacct(sec.lines)
            }
            // 作业刚离开队列时 sacct 可能还没写入最终状态（仍是 RUNNING / COMPLETING），稍等再查一次。
            let unsettled = slurmJobs.filter { finals[$0.id]?.state.isActive ?? false }
            if !unsettled.isEmpty {
                try? await Task.sleep(for: .seconds(20))
                let r2 = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                             script: RemoteScript.sacctScript(for: host, jobIDs: unsettled.map(\.id)), timeout: 20)
                if let sec = RemoteScript.parse(r2.stdout).sections["sacct"] {
                    for (k, v) in Parsers.sacct(sec.lines) { finals[k] = v }
                }
            }
        }

        for job in vanished {
            switch job.source {
            case .slurm:
                let f = finals[job.id]
                // 没有 sacct（集群未开启作业记录）但识别到了计算软件：用输出文件的最终状态判断成功与否。
                if f == nil, let app = job.app {
                    var final = app
                    let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                                script: AppDetectors.finalStateScript(id: job.id, dir: app.dir), timeout: 15)
                    if let fresh = AppDetectors.parse(r.stdout.components(separatedBy: "\n"))[job.id] { final = fresh }
                    let done = final.finished
                    let pos = final.current.map(AppProgress.compact) ?? "?"
                    let tot = final.total.map(AppProgress.compact) ?? "?"
                    let posText = final.total == nil ? "\(pos) \(final.unit)" : "\(pos)/\(tot) \(final.unit)"
                    history.record(host.id, HistoryEntry(id: job.id, name: job.name, state: done ? "COMPLETED" : "FAILED",
                                                         elapsed: job.elapsed, endedAt: Date(), exitCode: nil,
                                                         note: L("按 \(final.title) 输出判断：\(posText)", "from \(final.title) output: \(posText)"),
                                                         dir: job.workdir ?? app.dir))
                    batch.append(.init(kind: done ? .finished : (final.canJudge ? .failed : .info),
                                       title: "\(job.name) " + (done ? L("已完成", "finished") : (final.canJudge ? L("提前结束", "ended early") : L("已离开队列", "left the queue"))),
                                       subtitle: "\(final.title) \(posText) · #\(job.id)",
                                       hostName: host.displayName, hostID: host.id))
                    continue
                }
                var state = f?.state ?? .completed
                if state.isActive { state = .completed }
                history.record(host.id, HistoryEntry(id: job.id, name: job.name, state: f?.raw ?? state.rawValue,
                                                     elapsed: f?.elapsed ?? job.elapsed, endedAt: Date(),
                                                     exitCode: f?.exit, note: f == nil ? L("sacct 不可用，按离开队列记录", "no sacct; recorded when it left the queue") : nil,
                                                     dir: job.workdir ?? job.app?.dir))
                let elapsed = f?.elapsed ?? job.elapsed
                let time = elapsed.map { L("用时 ", "took ") + Format.duration($0) } ?? ""
                switch state {
                case .failed, .timeout, .cancelled:
                    batch.append(.init(kind: .failed, title: "\(job.name) \(state.label)",
                               subtitle: [f?.raw.capitalized ?? "", time].filter { !$0.isEmpty }.joined(separator: " · "),
                               hostName: host.displayName, hostID: host.id))
                default:
                    if f == nil {
                        // 没有 sacct：只知道离开了队列，不能断定成功。
                        batch.append(.init(kind: .info, title: L("\(job.name) 已离开队列", "\(job.name) left the queue"),
                                           subtitle: L("集群未开启作业记录，无法确认成功或失败 · ", "no job accounting; result unknown · ") + time, hostName: host.displayName, hostID: host.id))
                    } else {
                        batch.append(.init(kind: .finished, title: L("\(job.name) 已完成", "\(job.name) finished"),
                                           subtitle: time, hostName: host.displayName, hostID: host.id))
                    }
                }
            case .process:
                history.record(host.id, HistoryEntry(id: job.id, name: job.name, state: JobState.completed.rawValue,
                                                     elapsed: job.elapsed, endedAt: Date(), exitCode: nil,
                                                     note: job.watched ? L("监听的进程", "watched process") : nil,
                                                     dir: job.workdir ?? job.app?.dir))
                if job.watched { unwatch(hostID: host.id, pid: job.id) }
                var finalApp = job.app
                if let app = job.app {
                    // 最后一次采样可能还没到目标：再读一次输出文件的最终状态。
                    let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                                script: AppDetectors.finalStateScript(id: job.id, dir: app.dir), timeout: 15)
                    if let fresh = AppDetectors.parse(r.stdout.components(separatedBy: "\n"))[job.id] { finalApp = fresh }
                    DebugLog.log("[\(host.displayName)] \(app.title)结束时的最终状态：\(finalApp?.current.map { AppProgress.compact($0) } ?? "?")/\(finalApp?.total.map { AppProgress.compact($0) } ?? "?")")
                }
                if let app = finalApp, app.canJudge, let c = app.current {
                    // 计算软件：没到目标 / 没有正常结束标记就退出，基本是出错或被杀。
                    let done = app.finished
                    let folder = (app.dir as NSString).lastPathComponent
                    let pos = AppProgress.compact(c) + (app.total.map { "/" + AppProgress.compact($0) } ?? "") + " " + app.unit
                    batch.append(.init(kind: done ? .finished : .failed,
                                       title: app.title + (done ? L("完成", " finished") : L("提前结束", " ended early")),
                                       subtitle: (done ? pos : L("停在 ", "stopped at ") + pos) + " · " + folder,
                                       hostName: host.displayName, hostID: host.id))
                } else {
                    batch.append(.init(kind: .finished, title: L("\(job.name) 已结束", "\(job.name) ended"),
                               subtitle: job.elapsed.map { L("运行了至少 ", "ran for at least ") + Format.duration($0) } ?? "", hostName: host.displayName, hostID: host.id))
                }
            case .progressFile:
                break
            }
        }
    }

    private func handleArrays(host: HostConfig, elements: [(base: String, job: RemoteJob)], finished: [RemoteJob],
                              batch: inout [IslandEvent]) async {
        // 一次 sacct 查完：离开运行的元素 + 已经整体结束的数组（取全部元素的最终状态）。
        var ids = elements.map(\.job.id)
        ids += finished.compactMap(\.array?.baseID)
        var finals: [String: (state: JobState, raw: String, elapsed: TimeInterval?, exit: String)] = [:]
        if !ids.isEmpty, !sacctUnsupported.contains(host.id) {
            let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                        script: RemoteScript.sacctScript(for: host, jobIDs: Array(Set(ids))), timeout: 25)
            if let sec = RemoteScript.parse(r.stdout).sections["sacct"] { finals = Parsers.sacct(sec.lines) }
        }
        let finishedBases = Set(finished.compactMap(\.array?.baseID))
        for (base, e) in elements where !finishedBases.contains(base) {
            let key = arrayKey(host.id, base)
            var t = arrayTracks[key] ?? ArrayTrack()
            let st = finals[e.id]?.state ?? .completed
            if [.failed, .timeout, .cancelled].contains(st) {
                t.failed += 1
                if !t.alertedFailure && store.settings.arrayFirstFailureAlert {
                    t.alertedFailure = true
                    batch.append(.init(kind: .failed, title: L("\(e.name) 数组中有元素失败", "\(e.name): an array element failed"),
                                       subtitle: "#\(e.id) \(finals[e.id]?.raw ?? st.label)" + L(" · 之后的失败不再单独提醒", " · later failures won't alert separately"),
                                       hostName: host.displayName, hostID: host.id))
                }
            } else {
                t.done += 1
            }
            arrayTracks[key] = t
        }
        refreshTracks(host.id)

        for job in finished {
            guard let a = job.array else { continue }
            let key = arrayKey(host.id, a.baseID)
            var t = arrayTracks[key] ?? ArrayTrack()
            let mine = finals.filter { $0.key.hasPrefix(a.baseID + "_") && !$0.key.contains("[") }
            if !mine.isEmpty {
                t.done = mine.values.filter { $0.state == .completed }.count
                t.failed = mine.values.filter { [.failed, .timeout, .cancelled].contains($0.state) }.count
                t.accurate = true
            } else {
                t.done += a.running.count
            }
            let total = max(t.total, t.done + t.failed)
            history.record(host.id, HistoryEntry(id: a.baseID, name: job.name,
                                                 state: t.failed > 0 ? "FAILED" : "COMPLETED", elapsed: job.elapsed,
                                                 endedAt: Date(), exitCode: nil,
                                                 note: L("数组 ", "array ") + "\(t.done)✓ \(t.failed)✗", dir: job.workdir))
            batch.append(.init(kind: t.failed > 0 ? .failed : (t.accurate ? .finished : .info),
                               title: L("\(job.name) 数组已全部结束", "\(job.name): array finished"),
                               subtitle: L("\(t.done) 个成功", "\(t.done) done") + (t.failed > 0 ? L(" · \(t.failed) 个失败", " · \(t.failed) failed") : "") + L(" / 共 \(total) 个", " / \(total) total")
                                   + (t.accurate ? "" : L("（sacct 不可用，结果未确认）", " (no sacct; unconfirmed)")),
                               hostName: host.displayName, hostID: host.id))
            arrayTracks[key] = nil
        }
    }

    /// 同一次轮询里事件太多时合并成一条，避免连续弹窗。
    private func flush(_ batch: [IslandEvent], host: HostConfig) {
        guard !batch.isEmpty else { return }
        if batch.count <= 2 {
            batch.forEach(emit)
            return
        }
        let failed = batch.filter { $0.kind == .failed }.count
        let done = batch.filter { $0.kind == .finished }.count
        var parts: [String] = []
        if done > 0 { parts.append(L("\(done) 个完成", "\(done) finished")) }
        if failed > 0 { parts.append(L("\(failed) 个失败", "\(failed) failed")) }
        let started = batch.count - done - failed
        if started > 0 { parts.append(L("\(started) 个开始运行", "\(started) started")) }
        emit(.init(kind: failed > 0 ? .failed : .finished, title: parts.joined(separator: L("，", ", ")),
                   subtitle: batch.prefix(3).map(\.title).joined(separator: " · "), hostName: host.displayName, hostID: host.id))
    }

    func emit(_ event: IslandEvent) {
        // 静音的服务器：不弹提示、不发通知、不响铃。
        if let id = event.hostID, store.host(id)?.muted == true {
            DebugLog.log("提醒已静音：\(event.title)")
            return
        }
        DebugLog.log("提醒：\(event.title) · \(event.subtitle)（弹窗 \(store.settings.islandAlerts) 声音 \(store.settings.soundEnabled)）")
        onEvent?(event)
        if store.settings.soundEnabled, event.kind != .started {
            SoundPlayer.shared.play(event.kind == .failed ? .failure : (event.kind == .warning ? .warning : .success),
                                    volume: store.settings.soundVolume)
        }
        guard store.settings.islandAlerts else { return }
        eventQueue.append(event)
        if currentEvent == nil { showNextEvent() }
    }

    private func showNextEvent() {
        guard !eventQueue.isEmpty else { currentEvent = nil; return }
        currentEvent = eventQueue.removeFirst()
        eventDismissTask?.cancel()
        eventDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.currentEvent = nil
            try? await Task.sleep(for: .seconds(0.6))
            guard !Task.isCancelled else { return }
            self?.showNextEvent()
        }
    }

    func dismissEvent() {
        eventDismissTask?.cancel()
        eventQueue.removeAll()
        currentEvent = nil
    }

    private func checkDisks(host: HostConfig, new: HostSnapshot, batch: inout [IslandEvent]) {
        let threshold = store.settings.diskWarnThreshold
        var alerted = diskAlerted[host.id] ?? []
        for d in new.disks {
            if d.fraction >= threshold, !alerted.contains(d.mount) {
                alerted.insert(d.mount)
                batch.append(.init(kind: .warning, title: L("磁盘快满了：\(d.mount)", "Disk almost full: \(d.mount)"),
                                   subtitle: L("已用 \(Format.percent(d.fraction)) · 剩余 \(Format.bytes((d.totalKB - d.usedKB) * 1024))", "\(Format.percent(d.fraction)) used · \(Format.bytes((d.totalKB - d.usedKB) * 1024)) free"),
                                   hostName: host.displayName, hostID: host.id))
            } else if d.fraction < threshold - 0.03 {
                alerted.remove(d.mount)   // 回落后再次超过时会重新提醒
            }
        }
        diskAlerted[host.id] = alerted
    }

    func pollForDiagnosis(_ host: HostConfig) async {
        runningConfig[host.id] = host
        await pollOnce(host.id)
    }

    func setSnapshot(_ snap: HostSnapshot, for id: UUID) {
        snapshots[id] = snap
    }

    // MARK: - 汇总

    var orderedHosts: [(HostConfig, HostSnapshot)] {
        store.settings.hosts.filter(\.enabled).map { ($0, snapshots[$0.id] ?? HostSnapshot()) }
    }

    var totalRunning: Int { snapshots.values.reduce(0) { $0 + $1.runningCount } }
    var totalPending: Int { snapshots.values.reduce(0) { $0 + $1.pendingCount } }
    var hasProblem: Bool { snapshots.values.contains { $0.health.isProblem } }
    var isRefreshing: Bool { snapshots.values.contains { $0.isRefreshing } }

    /// 收起状态右侧显示的"主任务"：有真实进度的优先，否则取最接近完成的运行中作业。
    var leadJob: RemoteJob? {
        let running = snapshots.values.flatMap(\.jobs).filter { $0.state == .running && $0.fraction != nil }
        return running.max { a, b in
            if a.hasRealProgress != b.hasRealProgress { return !a.hasRealProgress }
            return (a.fraction ?? 0) < (b.fraction ?? 0)
        }
    }

    // MARK: - 诊断

    /// 设置页的"测试连接"：返回原始输出，方便核对命令是否符合预期。
    func diagnose(_ host: HostConfig) async -> String {
        let script = RemoteScript.build(for: host)
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script)
        var out = "$ ssh \(host.alias) \(host.commands.shell)   (\(String(format: "%.2fs", r.duration)), exit \(r.status))\n"
        if let problem = SSHRunner.classify(r, host: host) {
            switch problem {
            case .needsLogin(let m), .error(let m): out += "✗ \(m)\n"
            default: break
            }
        }
        if !r.stderr.isEmpty { out += "\n[stderr]\n" + r.stderr + "\n" }
        out += "\n[stdout]\n" + r.stdout
        return out
    }

    /// 检测远端有没有 squeue / nvidia-smi，用于自动判断类型。
    func detect(_ host: HostConfig) async -> (slurm: Bool, pbs: Bool, gpu: Bool, localSlurmd: Bool, info: String)? {
        var h = host
        h.commands.shell = host.commands.shell
        let r = await SSHRunner.run(host: h, remoteCommand: host.commands.shell, script: (host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n") + RemoteScript.detectScript, timeout: 20)
        guard r.status == 0 else { return nil }
        let out = r.stdout
        let slurm = out.contains("squeue=yes")
        return (slurm, !slurm && out.contains("qstat=yes") && out.contains("qselect=yes"), out.contains("nvidia-smi=yes"), out.contains("slurmd=yes"),
                out.components(separatedBy: "\n").last { !$0.isEmpty && !$0.contains("=") } ?? "")
    }

    // MARK: - 演示模式

    private var demoTick = 0

    private func applyDemo(_ host: HostConfig) {
        demoTick += 1
        let old = snapshots[host.id] ?? HostSnapshot()
        let new = DemoData.snapshot(for: host, tick: demoTick, previous: old)
        snapshots[host.id] = new
        if demoTick % 30 == 0, host.kind.isScheduler {
            emit(.init(kind: demoTick % 60 == 0 ? .failed : .finished,
                       title: demoTick % 60 == 0 ? "eval_mmlu 失败" : "pretrain_7b 已完成",
                       subtitle: demoTick % 60 == 0 ? "OUT_OF_MEMORY · 用时 0:42:18" : "用时 11:42:05",
                       hostName: host.displayName, hostID: host.id))
        }
    }
}
