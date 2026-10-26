import Foundation

extension MonitorEngine {
    /// 本机进度与服务器指标独立采样；暂停远端查询不应该冻结正在执行的本地 Action。
    func startLocalTaskMonitoring() {
        guard !demo, !IslandPreview.active, localTaskLoop == nil else { return }
        refreshLocalTasks()
        localTaskLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.refreshLocalTasks()
            }
        }
    }

    func refreshLocalTasks(from directory: URL = LocalTaskStore.directory) {
        let records = LocalTaskStore.read(from: directory)
        localTaskRecords = records
        let hosts = store.settings.hosts.filter(\.enabled)
        var grouped: [UUID: [RemoteJob]] = [:]
        for record in records {
            let id = LocalTaskStore.hostID(for: record, hosts: hosts)
            grouped[id, default: []].append(record.job)
            let old = localTaskStates[record.job.id]
            if localTasksLoaded, old != record.job.state, !record.job.state.isActive {
                let host = hosts.first { $0.id == id } ?? LocalTaskStore.localHost
                if !host.muted {
                    let kind: IslandEvent.Kind = record.job.state == .completed ? .finished
                        : record.job.state == .failed ? .failed : .info
                    let event = IslandEvent(kind: kind,
                        title: record.job.name + " · " + record.job.state.label,
                        subtitle: record.job.message ?? "", hostName: host.displayName, hostID: host.id, jobID: record.job.id)
                    // 本地部署同样遵守事件种类/关注范围；勿扰和服务器静音继续由 emit 处理。
                    for allowed in Self.alertable([event], settings: store.settings) { emit(allowed) }
                }
            }
            // 结束提醒筛选完再取消关注，保留已完成进度的停留显示。
            if !record.job.state.isActive {
                store.settings.starredJobs.removeAll { $0.hostID == id && $0.jobID == record.job.id }
            }
            localTaskStates[record.job.id] = record.job.state
        }
        for id in Set(localJobs.keys).union(grouped.keys) {
            var snap = snapshots[id] ?? HostSnapshot()
            snap.jobs = snap.jobs.filter { !$0.id.hasPrefix("local:") } + (grouped[id] ?? [])
            // 部署任务优先，避免服务器大量进程把用户刚触发的 Action 挤出卡片。
            snap.jobs.sort { a, b in
                if a.state.isActive != b.state.isActive { return a.state.isActive }
                return a.id.hasPrefix("local:") && !b.id.hasPrefix("local:")
            }
            if id == HostConfig.localTaskID { snap.health = .ok; snap.lastUpdate = Date() }
            setSnapshot(snap, for: id)
        }
        localJobs = grouped
        localTasksLoaded = true
        // 即使远端一分钟才刷新，也要按秒更新展示期限；不改动原始快照，切回 0 可恢复显示。
        if store.settings.progressFileStaySeconds > 0 { objectWillChange.send() }
    }

    func actionIsRunning(host: HostConfig, action: HostAction) -> Bool {
        let key = host.id.uuidString + ":" + action.id.uuidString
        if runningActions.contains(key) { return true }
        return localTaskRecords.contains {
            LocalTaskStore.hostID(for: $0, hosts: [host]) == host.id
                && ($0.actionID.caseInsensitiveCompare(action.id.uuidString) == .orderedSame
                    || ($0.actionID.isEmpty && $0.job.name == action.name))
                && $0.job.state.isActive
        }
    }

    func displayHost(_ id: UUID) -> HostConfig? {
        store.host(id) ?? (id == HostConfig.localTaskID ? LocalTaskStore.localHost : nil)
    }

    /// 显式点击才执行已保存的脚本。命令用 stdin 传递，避免拼接参数、泄露到进程列表。
    func runHostAction(host: HostConfig, action: HostAction, testRun: Bool = false) {
        // 启用开关决定快捷入口是否展示；设置页显式测试可运行禁用项，但仍校验脚本和重复运行。
        guard (action.enabled || testRun), action.isValid, !actionIsRunning(host: host, action: action) else { return }
        let key = host.id.uuidString + ":" + action.id.uuidString
        runningActions.insert(key)
        Task {
            if action.target == .remote, host.auth.needsLogin, !(await SSHRunner.masterAlive(host: host)) {
                guard await login(host) == nil else { runningActions.remove(key); return }
            }
            launchHostAction(host: host, action: action, key: key)
        }
    }

    func launchHostAction(host: HostConfig, action: HostAction, key: String) {
        let runID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let started = Date().timeIntervalSince1970
        let directory = LocalTaskStore.directory
        let file = directory.appendingPathComponent("deploy-" + runID + ".json")
        let bundled = Bundle.main.url(forResource: "si-deploy", withExtension: nil)
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("remote/si-deploy")
        let wrapper = bundled ?? source
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        var args = ["python3", wrapper.path, "run", "--local", "--host", host.id.uuidString,
                    "--action-id", action.id.uuidString, "--run-id", runID,
                    "--name", String(action.name.prefix(80))]
        let stateRoot = directory.deletingLastPathComponent().deletingLastPathComponent()
        args += ["--state-dir", stateRoot.path]
        if action.target == .remote { args.append("--ssh") }
        process.arguments = args
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let input = Pipe()
        process.standardInput = input

        // 先写同一个 run_id 的占位记录，极短任务或 Python 不可用也能留下可见结果。
        func fallback(status: String, message: String, pid: Int32 = 0) {
            let value: [String: Any] = [
                "name": action.name, "status": status, "progress": NSNull(), "message": message,
                "updated": Date().timeIntervalSince1970,
                "deployment": ["local": true, "run_id": runID, "host": host.id.uuidString,
                               "action_id": action.id.uuidString, "started": started, "pid": pid]
            ]
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if let data = try? JSONSerialization.data(withJSONObject: value) {
                try? data.write(to: file, options: .atomic)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        process.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                let state = (try? Data(contentsOf: file)).flatMap {
                    (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
                }
                if state == nil || state?["status"] as? String == "running" {
                    let uncertain = finished.terminationStatus == 255 || (action.target == .remote
                        && finished.terminationReason == .uncaughtSignal)
                    fallback(status: uncertain ? "unknown" : "failed",
                             message: uncertain ? L("连接中断，远端结果未知", "Connection lost; remote result unknown")
                                : L("监控未正常结束，请检查 Python 3 与执行环境", "Monitor exited unexpectedly; check Python 3 and execution environment"))
                }
                self.actionProcesses[key] = nil
                self.runningActions.remove(key)
                self.refreshLocalTasks()
            }
        }
        fallback(status: "running", message: L("正在启动…", "Starting…"))
        do {
            // 每次执行使用当前启用规则的快照；修改匹配配置不需要改包装器或重新打包。
            let rules = store.settings.progressRules.filter(\.isLogUsable)
            if !rules.isEmpty {
                let runtime = stateRoot.appendingPathComponent("local/runtime")
                try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
                let snapshot = runtime.appendingPathComponent("rules-" + runID + ".json")
                try ProgressRulePack(rules: rules).data().write(to: snapshot, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshot.path)
                process.arguments = args + ["--rules", snapshot.path]
            }
            try SSHRunner.run(host: host, action: action, monitoredProcess: process)
            actionProcesses[key] = process
            // 大段脚本的管道写入放到后台，避免堵住设置窗口或灵动岛的主线程。
            let prelude = "set -e\nset -o pipefail\nexport BUILDKIT_PROGRESS=plain\nexport PYTHONUNBUFFERED=1\n"
            let script = prelude + (action.target == .remote
                ? (host.importShellPath ? SSHRunner.pathPrelude : "") + host.commands.preamble + "\n" : "") + action.command + "\n"
            DispatchQueue.global(qos: .userInitiated).async {
                try? input.fileHandleForWriting.write(contentsOf: Data(script.utf8))
                try? input.fileHandleForWriting.close()
            }
        } catch {
            try? input.fileHandleForWriting.close()
            fallback(status: "failed", message: L("无法启动 Action：", "Cannot start Action: ") + error.localizedDescription)
            runningActions.remove(key)
        }
        refreshLocalTasks()
    }
}
