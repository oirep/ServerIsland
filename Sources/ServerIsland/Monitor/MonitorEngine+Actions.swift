import Foundation

/// 任务详情（只在用户点开时按需查询）。
struct JobDetail: Equatable {
    struct LogTail: Equatable {
        var path: String?
        var lines: [String] = []
        /// 读不到日志时的说明（如"输出到终端"、"没有读取权限"）。
        var note: String?
    }

    var fields: [(String, String)] = []
    var stdout = LogTail()
    var stderr: LogTail?
    var error: String?
    var fetchedAt = Date()

    static func == (a: JobDetail, b: JobDetail) -> Bool {
        a.fields.map { $0.0 + "=" + $0.1 } == b.fields.map { $0.0 + "=" + $0.1 }
            && a.stdout == b.stdout && a.stderr == b.stderr && a.error == b.error
    }
}

enum CancelOutcome: Equatable {
    case done(String)
    case aborted(String)
}

extension MonitorEngine {
    // MARK: - 详情

    func fetchDetail(host: HostConfig, job: RemoteJob) async -> JobDetail {
        var d = JobDetail()
        guard job.source != .progressFile else {
            d.fields = [(L("名称", "Name"), job.name)] + (job.message.map { [(L("进度说明", "Progress"), $0)] } ?? [])
            d.stdout.note = L("进度文件条目没有对应的进程或作业", "Progress-file entries have no process or job")
            return d
        }
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: RemoteScript.detailScript(host: host, job: job), timeout: 20)
        if let problem = SSHRunner.classify(r, host: host) {
            switch problem {
            case .needsLogin(let m), .error(let m): d.error = m
            default: break
            }
            return d
        }
        let p = RemoteScript.parse(r.stdout)
        switch job.source {
        case .slurm: fillSlurm(&d, p, job: job)
        case .process: fillProcess(&d, p, job: job)
        case .progressFile: break
        }
        d.stdout = logTail(p.sections["stdout"])
        if let e = p.sections["stderr"], e.lines.contains(where: { $0.hasPrefix(RemoteScript.marker + "PATH") }) {
            d.stderr = logTail(e)
        }
        if d.stdout.path == nil && d.stdout.note == nil {
            d.stdout.note = job.source == .slurm ? L("没有找到 StdOut 路径（作业可能已结束太久）", "No StdOut path found (the job may have ended too long ago)") : L("没有找到日志", "No log found")
        }
        return d
    }

    private func fillSlurm(_ d: inout JobDetail, _ p: RemoteScript.Parsed, job: RemoteJob) {
        if let sec = p.sections["scontrol"], sec.exitCode == 0, let line = sec.lines.first(where: { $0.contains("JobId=") }) {
            let kv = Parsers.keyValues(line)
            let keys: [(String, String)] = [
                ("JobState", L("状态", "State")), ("Reason", L("原因", "Reason")), ("RunTime", L("已运行", "Elapsed")), ("TimeLimit", L("时间上限", "Time limit")),
                ("SubmitTime", L("提交时间", "Submitted")), ("StartTime", L("开始时间", "Started")), ("Partition", L("分区", "Partition")), ("NodeList", L("节点", "Nodes")),
                ("NumCPUs", "CPU"), ("TRES", L("资源", "Resources")), ("WorkDir", L("工作目录", "Directory")), ("ExitCode", L("退出码", "Exit code")),
            ]
            for (k, label) in keys {
                guard var v = kv[k], !v.isEmpty, v != "(null)", v != "None", v != "Unknown" else { continue }
                if k == "TRES" || k == "AllocTRES" { v = v.replacingOccurrences(of: "billing=", with: "") }
                d.fields.append((label, v))
            }
        } else if let sec = p.sections["sacct"], let line = sec.lines.first(where: { $0.hasPrefix(job.id) }) {
            // 已经结束太久，scontrol 查不到了，用 sacct。
            let f = line.components(separatedBy: "|")
            let labels = [L("作业号", "Job ID"), L("名称", "Name"), L("分区", "Partition"), L("状态", "State"), L("退出码", "Exit code"), L("用时", "Elapsed"), L("开始时间", "Started"), L("结束时间", "Ended"), L("节点", "Nodes"), L("资源", "Resources"), L("峰值内存", "Peak memory")]
            for (i, label) in labels.enumerated() where i < f.count && !f[i].isEmpty && i != 0 && i != 1 {
                d.fields.append((label, f[i]))
            }
        } else {
            d.error = L("scontrol / sacct 都查不到这个作业", "Neither scontrol nor sacct knows this job")
        }
    }

    private func fillProcess(_ d: inout JobDetail, _ p: RemoteScript.Parsed, job: RemoteJob) {
        guard let ps = p.sections["ps"], let line = ps.lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            d.error = L("进程已经结束", "The process has ended")
            return
        }
        let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        if f.count >= 8 {
            d.fields.append((L("PID / 父进程", "PID / parent"), "\(f[0]) / \(f[1])"))
            d.fields.append((L("用户", "User"), f[2]))
            if let e = Double(f[3]) { d.fields.append((L("已运行", "Elapsed"), Format.duration(e))) }
            d.fields.append((L("CPU / 内存", "CPU / MEM"), "\(f[4])% / \(f[5])%"))
            if let rss = Double(f[6]) { d.fields.append((L("常驻内存", "RSS"), Format.bytes(rss * 1024))) }
            d.fields.append((L("状态", "State"), f[7]))
        }
        if let g = p.sections["gpu"]?.lines.first(where: { $0.contains(",") }) {
            let mem = g.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if let mb = Double(mem) { d.fields.append((L("显存", "VRAM"), Format.bytes(mb * 1_048_576))) }
        }
        if let cwd = p.sections["cwd"]?.lines.first(where: { !$0.isEmpty }) { d.fields.append((L("工作目录", "Directory"), cwd)) }
        if let args = p.sections["args"]?.lines.first(where: { !$0.isEmpty }) { d.fields.append((L("命令", "Command"), args)) }
    }

    private func logTail(_ sec: RemoteScript.Section?) -> JobDetail.LogTail {
        var t = JobDetail.LogTail()
        guard let sec else { return t }
        for line in sec.lines {
            if line.hasPrefix(RemoteScript.marker + "PATH ") {
                t.path = String(line.dropFirst((RemoteScript.marker + "PATH ").count))
            } else if line == RemoteScript.marker + "UNREADABLE" {
                t.note = L("日志文件不存在或没有读取权限", "Log file missing or not readable")
            } else if line.hasPrefix(RemoteScript.marker + "NOFILE") {
                let target = line.dropFirst((RemoteScript.marker + "NOFILE").count).trimmingCharacters(in: .whitespaces)
                t.note = target.contains("pts") || target.contains("tty")
                    ? L("输出直接打印到终端（tmux / screen），读不到日志；可以用 > log.txt 重定向", "Output goes to a terminal (tmux / screen); redirect with > log.txt to see it here")
                    : (target.isEmpty ? L("读不到这个进程的输出（可能不属于你）", "Cannot read this process output (it may not be yours)") : L("输出到 \(target)，不是文件", "Output goes to \(target), not a file"))
            } else {
                t.lines.append(line)
            }
        }
        while t.lines.last?.isEmpty == true { t.lines.removeLast() }
        return t
    }

    // MARK: - 取消

    func cancel(host: HostConfig, job: RemoteJob, sampledAt: Date?, force: Bool) async -> CancelOutcome {
        guard host.allowCancel else { return .aborted(L("这台服务器没有开启「允许取消任务」", "“Allow Cancelling” is off for this server")) }
        let expected = job.elapsed.map { e in e + (sampledAt.map { Date().timeIntervalSince($0) } ?? 0) }
        guard let script = RemoteScript.cancelScript(host: host, job: job, expectedElapsed: expected, force: force) else {
            return .aborted(L("这个条目不能取消", "This entry cannot be cancelled"))
        }
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 20)
        if let problem = SSHRunner.classify(r, host: host) {
            if case .error(let m) = problem { return .aborted(m) }
            if case .needsLogin(let m) = problem { return .aborted(m) }
        }
        let out = r.stdout
        if let line = out.components(separatedBy: "\n").first(where: { $0.hasPrefix(RemoteScript.marker + "ABORT") }) {
            return .aborted(String(line.dropFirst((RemoteScript.marker + "ABORT ").count)))
        }
        if out.contains(RemoteScript.marker + "DONE") {
            refresh(host.id)
            let what = job.source == .slurm ? "scancel \(job.id)" : "kill -\(force ? "KILL" : "TERM") \(job.id)"
            return .done(L("已执行 \(what)", "Ran \(what)"))
        }
        let err = (r.stderr + out).components(separatedBy: "\n")
            .first { !$0.isEmpty && !$0.hasPrefix(RemoteScript.marker) } ?? L("未知错误", "Unknown error")
        return .aborted(err)
    }

    // MARK: - 最近 24 小时

    /// Slurm 优先用 sacct（服务器上的完整记录）；不支持时退回到本机观察到的记录。
    func fetchHistory(host: HostConfig) async -> (entries: [HistoryEntry], fromServer: Bool) {
        let local = history.entries(for: host.id)
        guard host.kind == .slurm, !sacctUnsupported.contains(host.id) else { return (local, false) }
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: RemoteScript.historyScript(host: host), timeout: 25)
        guard let sec = RemoteScript.parse(r.stdout).sections["history"], sec.exitCode == 0 else {
            if r.status != 255 { sacctUnsupported.insert(host.id) }   // 命令本身不可用：本次运行内不再尝试
            return (local, false)
        }
        return (Parsers.history(sec.lines), true)
    }

    // MARK: - 监听进程

    func topProcesses(host: HostConfig) async -> [RemoteJob]? {
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: RemoteScript.topProcessesScript(host: host), timeout: 20)
        let p = RemoteScript.parse(r.stdout)
        guard let sec = p.sections["procs"] else { return nil }
        let gpu = p.sections["gpuapps"].map { Parsers.gpuApps($0.lines) } ?? [:]
        // 这里不套用"包含"过滤，但仍然去掉系统 / 桌面进程。
        return Array(Parsers.processes(sec.lines, filter: "", exclude: host.processExclude, gpuMem: gpu)
            .sorted { ($0.gpuMemoryMB ?? 0, $0.cpuPercent ?? 0) > ($1.gpuMemoryMB ?? 0, $1.cpuPercent ?? 0) }
            .prefix(12))
    }

    func isWatched(hostID: UUID, pid: String) -> Bool {
        store.host(hostID)?.watched.contains { $0.pid == pid } ?? false
    }

    func watch(hostID: UUID, job: RemoteJob) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == hostID }),
              !store.settings.hosts[i].watched.contains(where: { $0.pid == job.id }) else { return }
        let started = job.elapsed.map { Date().addingTimeInterval(-$0) }
        store.settings.hosts[i].watched.append(WatchedProcess(pid: job.id, name: job.name, startedAt: started))
        sync()
    }

    func unwatch(hostID: UUID, pid: String) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == hostID }) else { return }
        store.settings.hosts[i].watched.removeAll { $0.pid == pid }
        sync()
    }

    /// 弹出原生密码框登录，成功后立即刷新。
    func login(_ host: HostConfig) async -> String? {
        loggingIn.insert(host.id)
        defer { loggingIn.remove(host.id) }
        let err = await SSHRunner.loginWithPrompt(host: host)
        DebugLog.log("[\(host.displayName)] 弹窗登录：\(err ?? "成功")")
        if err == nil { refresh(host.id) }
        return err
    }

    /// 设置页"检查命令"：在当前环境（含"连接后先执行"和补全 PATH）下查找常用命令。
    func checkEnvironment(_ host: HostConfig) async -> [(String, String?)] {
        let names = ["squeue", "sinfo", "sacct", "nvidia-smi", "gpumd", "nep"]
        var script = host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n"
        script += "for c in \(names.joined(separator: " ")); do printf '%s=%s\\n' \"$c\" \"$(command -v $c 2>/dev/null)\"; done\n"
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 20)
        var found: [String: String] = [:]
        for line in r.stdout.components(separatedBy: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { found[String(line[..<eq])] = v }
        }
        return names.map { ($0, found[$0]) }
    }

    func setKind(_ hostID: UUID, _ kind: HostKind, showGPU: Bool? = nil, alsoProcesses: Bool? = nil) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == hostID }) else { return }
        store.settings.hosts[i].kind = kind
        if let g = showGPU { store.settings.hosts[i].showGPU = g }
        if let a = alsoProcesses { store.settings.hosts[i].slurmAlsoProcesses = a }
        DebugLog.log("[\(store.settings.hosts[i].displayName)] 类型改为 \(kind.label)")
        sync()
    }

    func toggleMute(_ hostID: UUID) {
        guard let i = store.settings.hosts.firstIndex(where: { $0.id == hostID }) else { return }
        store.settings.hosts[i].muted.toggle()
    }
}

// MARK: - 测试进度识别规则

extension MonitorEngine {
    /// 在指定服务器的指定目录上只读地跑一次规则。
    func testRule(_ rule: ProgressRule, host: HostConfig, dir: String) async -> RuleTestResult {
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: AppDetectors.ruleTestScript(dir: dir, rule: rule), timeout: 20)
        if r.timedOut { return .init(ok: false, headline: L("连接超时", "Timed out")) }
        if r.status == 255 {
            let msg = r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(ok: false, headline: L("连接失败", "Connection failed"), notes: msg.isEmpty ? [] : [String(msg.prefix(200))])
        }
        return AppDetectors.interpretTest(r.stdout, rule: rule)
    }
}
