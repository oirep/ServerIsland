import Foundation

/// 自检：异常情况下不误报（队列查询失败、结果未知、通知合并）、配置文件损坏时不被覆盖。
enum SelfTestMonitor {
    static func run(_ check: (Bool, String) -> Void) {
        // —— 队列查询失败：沿用上一份任务列表，不当成任务结束 ——
        let host = HostConfig(alias: "x", kind: .slurm)
        let before = [RemoteJob(id: "101", name: "relax", state: .running, source: .slurm)]
        func listed(_ rc: Int, _ lines: [String]) -> Bool {
            MonitorEngine.jobsListed(host: host, parsed: RemoteScript.parse((["@@SI:BEGIN", "@@SI:SEC squeue"] + lines + ["@@SI:RC \(rc)"]).joined(separator: "\n")))
        }
        let failed = listed(1, ["slurm_load_jobs error: Socket timed out on send/recv operation"])
        check(!failed && MonitorEngine.jobsAfterPoll(built: [], previous: before, listed: failed).map(\.id) == ["101"],
              "squeue 出错：沿用上一份任务列表，不产生结束提醒")
        let empty = listed(0, [])
        check(empty && MonitorEngine.jobsAfterPoll(built: [], previous: before, listed: empty).isEmpty,
              "squeue 成功且为空：任务确实离开了队列")

        // —— 离开队列的 Slurm 作业：只有 COMPLETED 才算成功 ——
        func outcome(_ raw: String?) -> (state: String, kind: IslandEvent.Kind) {
            MonitorEngine.slurmOutcome(raw.map { (JobState(slurm: $0), $0, nil, "") })
        }
        check(outcome(nil) == (HistoryEntry.endedUnknown, .info), "没有 sacct：历史记成“已结束”，提醒为结果未知")
        check(outcome("RUNNING") == (HistoryEntry.endedUnknown, .info) && outcome("COMPLETING") == (HistoryEntry.endedUnknown, .info),
              "sacct 仍显示运行中：不当成完成")
        check(outcome("COMPLETED") == ("COMPLETED", .finished) && outcome("OUT_OF_MEMORY") == ("OUT_OF_MEMORY", .failed)
              && outcome("CANCELLED by 123") == ("CANCELLED by 123", .failed) && outcome("SPECIAL_EXIT") == ("SPECIAL_EXIT", .info),
              "sacct 结束状态：完成 / 失败 / 不认识的状态")

        // —— 数组整体结束：sacct 里还有运行中的元素时不算成功 ——
        let arr = MonitorEngine.arrayCounts(Parsers.sacct(["500_1|scan|COMPLETED|00:10:00|0:0", "500_2|scan|RUNNING|00:09:00|0:0"]).values.map(\.state))
        check(arr == (1, 0, 1) && MonitorEngine.arrayOutcome(failed: arr.failed, accurate: arr.unknown == 0) == (HistoryEntry.endedUnknown, .info),
              "数组：还有元素显示运行中时，记成结果未知")
        check(MonitorEngine.arrayOutcome(failed: 0, accurate: true) == ("COMPLETED", .finished)
              && MonitorEngine.arrayOutcome(failed: 1, accurate: false) == ("FAILED", .failed), "数组：全部确认完成才算成功，有失败就算失败")
        let partial = MonitorEngine.arrayCounts([.completed], expectedTotal: 2)
        check(partial == (1, 0, 1)
              && MonitorEngine.arrayOutcome(failed: partial.failed, accurate: partial.unknown == 0) == (HistoryEntry.endedUnknown, .info),
              "数组：已知 2 个元素、只返回 1 个完成记录时不报成功")
        let complete = MonitorEngine.arrayCounts([.completed, .completed], expectedTotal: 2)
        check(complete == (2, 0, 0)
              && MonitorEngine.arrayOutcome(failed: complete.failed, accurate: complete.unknown == 0) == ("COMPLETED", .finished),
              "数组：返回全部元素的完成记录才报成功")

        // —— 完整的处理流程（ingest：解析 → 任务列表 → 事件），用样例输出走几轮 ——
        let lang = Lang.setting   // 新建的 ConfigStore 会把语言设成默认值，测完改回来
        for (ok, name) in ingestScenarios() { check(ok, name) }
        Lang.setting = lang

        // —— 多条通知合并：按种类计数 ——
        func events(_ kinds: [IslandEvent.Kind]) -> [IslandEvent] {
            kinds.enumerated().map { IslandEvent(kind: $1, title: "t\($0)", subtitle: "", hostName: "h") }
        }
        let unknown = MonitorEngine.merged(events([.info, .info, .info]), hostName: "h", hostID: nil)
        check(unknown.kind == .info && unknown.title == "3 个结果未知", "合并：3 条结果未知不会变成“开始运行”")
        let mixed = MonitorEngine.merged(events([.started, .started, .warning]), hostName: "h", hostID: nil)
        check(mixed.kind == .warning && mixed.title == "2 个开始运行，1 条警告", "合并：开始运行和磁盘警告分开计数")
        let all = MonitorEngine.merged(events([.finished, .failed, .info, .started]), hostName: "h", hostID: nil)
        check(all.kind == .failed && all.title == "1 个完成，1 个失败，1 个结果未知，1 个开始运行", "合并：有失败时按失败提醒")

        // —— 关注与提醒设置 ——
        let hid = UUID()
        var st = AppSettings()
        st.starredJobs = [StarredJob(hostID: hid, jobID: "101", name: "relax")]
        func ev(_ k: IslandEvent.Kind, _ job: String?) -> IslandEvent {
            IslandEvent(kind: k, title: "t", subtitle: "", hostName: "h", hostID: hid, jobID: job)
        }
        check(st.allowsAlert(ev(.finished, "102")) && st.allowsAlert(ev(.started, "101")), "提醒设置：默认提醒全部任务")
        st.alertScope = .starred
        check(st.allowsAlert(ev(.finished, "101")) && !st.allowsAlert(ev(.finished, "102")) && !st.allowsAlert(ev(.info, "102")),
              "提醒设置：只提醒关注的任务")
        check(st.allowsAlert(ev(.warning, nil)), "提醒设置：磁盘等服务器提醒不受关注范围影响")
        st.alertFailed = false; st.alertUnknown = false; st.alertStarted = false
        check(!st.allowsAlert(ev(.failed, "101")) && !st.allowsAlert(ev(.info, "101")) && !st.allowsAlert(ev(.started, "101"))
              && st.allowsAlert(ev(.finished, "101")), "提醒设置：开始 / 失败 / 结果未知分别开关")
        check(MonitorEngine.alertable([ev(.finished, "4242"), ev(.finished, "4343")], settings: st, watchedPIDs: ["4242"]).map(\.jobID) == ["4242"],
              "提醒设置：手动监听的进程在“只提醒关注的任务”时照常提醒")
        let jobs = ["1", "2", "3"].map { RemoteJob(id: $0, name: $0, state: .running, source: .slurm) }
        check(MonitorEngine.starredFirst(jobs) { $0.id == "3" }.map(\.id) == ["3", "1", "2"], "关注：关注的任务排在前面，其余顺序不变")
        if let data = try? JSONEncoder().encode(st), let back = try? JSONDecoder().decode(AppSettings.self, from: data),
           let old = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)) {
            check(back.starredJobs == st.starredJobs && back.alertScope == .starred && !back.alertFailed && back.alertFinished,
                  "配置：关注和提醒设置可以保存、读回")
            check(old.starredJobs.isEmpty && old.alertScope == .all && old.alertStarted && old.alertFinished && old.alertFailed && old.alertUnknown,
                  "配置：旧配置文件默认提醒全部任务的全部事件")
        } else { check(false, "配置：关注和提醒设置编码失败") }

        // —— 勿扰时段 ——
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        func at(_ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: h, minute: m))! }
        var q = AppSettings()
        check(!q.isQuiet(at: at(23, 30), calendar: cal), "勿扰：默认关闭")
        q.quietHours = true
        check(q.isQuiet(at: at(23, 0), calendar: cal) && q.isQuiet(at: at(2, 0), calendar: cal) && q.isQuiet(at: at(7, 59), calendar: cal)
              && !q.isQuiet(at: at(8, 0), calendar: cal) && !q.isQuiet(at: at(22, 59), calendar: cal), "勿扰：跨午夜 23:00–08:00")
        q.quietStart = 12 * 60; q.quietEnd = 14 * 60
        check(q.isQuiet(at: at(13, 0), calendar: cal) && !q.isQuiet(at: at(14, 0), calendar: cal) && !q.isQuiet(at: at(11, 59), calendar: cal),
              "勿扰：白天 12:00–14:00")
        q.quietEnd = 12 * 60
        check(!q.isQuiet(at: at(12, 0), calendar: cal), "勿扰：起止相同时不算勿扰")
        check(q.quietLabel == "12:00–12:00" && AppSettings.clock(23 * 60 + 30) == "23:30", "勿扰：时间文字")

        // —— 设置的导入导出 ——
        var cur = AppSettings()
        var a1 = HostConfig(alias: "a1"); a1.displayName = "A"
        cur.hosts = [a1]
        cur.islandScreen = "Studio Display"
        var imp = AppSettings()
        let jump = HostConfig(alias: "jump")
        var b1 = HostConfig(alias: "b1", kind: .slurm); b1.jumpHostID = jump.id
        var orphan = HostConfig(alias: "c1"); orphan.jumpHostID = UUID()
        var dup = HostConfig(alias: "a1")   // 和当前的 a1 连接目标相同
        dup.displayName = "A copy"
        imp.hosts = [jump, b1, orphan, dup]
        imp.defaultInterval = 300
        imp.starredJobs = [StarredJob(hostID: b1.id, jobID: "1"), StarredJob(hostID: UUID(), jobID: "2")]
        let data = (try? ConfigTransfer.exportData(imp)) ?? Data()
        let back = try? ConfigTransfer.read(data)
        check(back?.hosts.count == 4 && back?.defaultInterval == 300, "导入导出：导出的文件可以读回")
        check((try? ConfigTransfer.read(Data(#"{"name":"x"}"#.utf8))) == nil && (try? ConfigTransfer.read(Data("not json".utf8))) == nil,
              "导入导出：不是设置文件时拒绝")
        let replaced = ConfigTransfer.apply(current: cur, imported: imp, mode: .replace)
        check(replaced.hosts.count == 4 && replaced.defaultInterval == 300 && replaced.islandScreen == "Studio Display",
              "导入导出：替换全部设置，保留本机的显示器选择")
        check(replaced.hosts.first { $0.alias == "b1" }?.jumpHostID == jump.id && replaced.hosts.first { $0.alias == "c1" }?.jumpHostID == nil
              && replaced.starredJobs.map(\.jobID) == ["1"], "导入导出：去掉指向不存在服务器的跳板机和关注")
        let added = ConfigTransfer.apply(current: cur, imported: imp, mode: .addHosts)
        check(added.hosts.map(\.alias) == ["a1", "jump", "b1", "c1"] && added.defaultInterval == cur.defaultInterval,
              "导入导出：只添加新的服务器（连接目标相同的跳过），其它设置不动")

        // Windows / Linux 版导出的文件（多了 displayMode、sshBackend、petX 等跨平台版专有的字段）
        let fromCross = #"{"hosts":[{"id":"0A1B2C3D-0000-4000-8000-000000000001","alias":"hpc","kind":"slurm","auth":"key"}],"displayMode":"pet","sshBackend":"managed","petX":120,"quietHours":true,"quietStart":1320,"quietEnd":420,"alertScope":"starred","starredJobs":[{"hostID":"0A1B2C3D-0000-4000-8000-000000000001","jobID":"9","name":"relax","since":782700000}]}"#
        let crossRead = try? ConfigTransfer.read(Data(fromCross.utf8))
        check(crossRead?.hosts.first?.kind == .slurm && crossRead?.quietLabel == "22:00–07:00" && crossRead?.alertScope == .starred
              && crossRead?.starredJobs.first?.jobID == "9", "导入导出：读取 Windows / Linux 版导出的设置")

        // —— 配置文件：首次启动 / 正常 / 损坏（先备份） ——
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-config-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("config.json")
        let missing = ConfigStore.load(from: file)
        check(missing.settings == nil && missing.problem == nil, "配置：首次启动没有文件，不算出错")
        try? Data("{}".utf8).write(to: file)
        check(ConfigStore.load(from: file).settings != nil, "配置：缺字段时补默认值")
        let broken = "{\"hosts\": [ {\"alias\": \"a\""
        try? Data(broken.utf8).write(to: file)
        let bad = ConfigStore.load(from: file)
        let backups = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("config.broken-") }
        check(bad.settings == nil && bad.problem != nil && !bad.blockSave && backups.count == 1
              && (try? String(contentsOf: dir.appendingPathComponent(backups[0]), encoding: .utf8)) == broken,
              "配置：读取失败时先备份原文件并说明原因")
    }

    /// 一段样例输出：每段 (名字, 退出码, 行)；退出码为 nil 时这段整个缺失（输出被截断等）。
    private static func output(_ secs: [(String, Int32?, [String])]) -> RemoteScript.Parsed {
        var lines = ["@@SI:BEGIN"]
        for (name, rc, body) in secs {
            guard let rc else { continue }
            lines += ["@@SI:SEC \(name)"] + body + ["@@SI:RC \(rc)"]
        }
        return RemoteScript.parse((lines + ["@@SI:END"]).joined(separator: "\n"))
    }

    /// 用一个不连网的引擎（主机设为停用，不会真的轮询）走几轮 ingest，返回 (是否通过, 名字)。
    private static func ingestScenarios() -> [(Bool, String)] {
        final class Results: @unchecked Sendable { var items: [(Bool, String)] = [] }
        let results = Results()
        let sem = DispatchSemaphore(value: 0)
        Task { @MainActor in
            let store = ConfigStore(persist: false)
            store.settings.soundEnabled = false
            store.settings.islandAlerts = false
            let engine = MonitorEngine(store: store)
            var events: [IslandEvent] = []
            engine.onEvent = { events.append($0) }
            @MainActor func host(_ kind: HostKind, _ edit: (inout HostConfig) -> Void = { _ in }) -> HostConfig {
                var h = HostConfig(alias: "x", kind: kind)
                h.enabled = false
                edit(&h)
                store.settings.hosts.append(h)
                return h
            }
            @MainActor func ingest(_ h: HostConfig, _ secs: [(String, Int32?, [String])]) async {
                await engine.ingest(host: store.host(h.id) ?? h, parsed: output(secs), latency: 0.1)
            }
            let py = "4242 100 50.0 1000 python train.py"

            // 直连：进程列表出错的那一轮不报结束，下一轮读全了才报
            let d = host(.direct)
            await ingest(d, [("procs", 0, [py])])
            await ingest(d, [("procs", 1, [])])
            results.items.append((events.isEmpty && engine.snapshots[d.id]?.jobs.map(\.id) == ["4242"], "流程：进程列表出错时不报结束，列表沿用上一轮"))
            await ingest(d, [("procs", 0, [])])
            results.items.append((events.count == 1 && events.first?.kind == .finished, "流程：之后读全了、进程确实不在了才报结束"))

            // Slurm：squeue 出错的那一轮不报结束
            events = []
            let s = host(.slurm)
            await ingest(s, [("squeue", 0, ["101|relax|RUNNING|1:00:00|2:00:00|1|cn01|cpu"])])
            await ingest(s, [("squeue", 1, ["slurm_load_jobs error: Socket timed out on send/recv operation"])])
            results.items.append((events.isEmpty && engine.snapshots[s.id]?.jobs.map(\.id) == ["101"], "流程：squeue 出错时不报结束"))

            // 关闭"监控任务"、只读进度文件：没有队列 / 进程段也照常更新
            let p = host(.direct) { $0.watchJobs = false }
            await ingest(p, [("progress", 0, ["@@SI:FILE /home/u/.serverisland/progress/a.json",
                                               #"{"name":"train","progress":0.4,"message":"step 4/10"}"#])])
            results.items.append((engine.snapshots[p.id]?.jobs.filter { $0.source == .progressFile }.count == 1, "流程：关闭监控任务时进度文件照常显示"))

            // 手动监听：watch 段缺失时不报结束、不取消监听；确实不在了才报
            events = []
            let w = host(.direct) { $0.watched = [WatchedProcess(pid: "999", name: "sim")] }
            await ingest(w, [("procs", 0, []), ("watch", 0, ["999 100 1.0 100 ./sim"])])
            await ingest(w, [("procs", 0, []), ("watch", nil, [])])
            results.items.append((events.isEmpty && store.host(w.id)?.watched.count == 1, "流程：监听段缺失时不报结束、不取消监听"))
            await ingest(w, [("procs", 0, []), ("watch", 0, [])])
            results.items.append((events.count == 1 && store.host(w.id)?.watched.isEmpty == true, "流程：监听的进程确实不在了才报结束"))

            // 数组总数随运行中任务保存，重启后用它检查 accounting 的覆盖范围。
            let a = host(.slurm)
            var array = RemoteJob(id: "500", name: "scan", state: .running, source: .slurm)
            array.array = ArrayInfo(baseID: "500", total: 2)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-array-test-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: dir) }
            let saved = HistoryStore(directory: dir)
            saved.setActive(a.id, [array])
            results.items.append((HistoryStore(directory: dir).activeJobs(for: a.id).first?.arrayTotal == 2,
                                  "数组历史：重启后保留已知总数"))
            array.array?.total = 3
            saved.setActive(a.id, [array])
            results.items.append((HistoryStore(directory: dir).activeJobs(for: a.id).first?.arrayTotal == 3,
                                  "数组历史：总数变化时立即保存"))

            engine.history.setActive(a.id, [RemoteJob(id: "500", name: "scan", state: .running, source: .slurm,
                                                     array: ArrayInfo(baseID: "500", total: 2))])
            let gone = engine.history.activeJobs(for: a.id)
            events = []
            for (states, expected, label) in [
                (["RUNNING"], HistoryEntry.endedUnknown, "仍运行"),
                (["SPECIAL_EXIT"], HistoryEntry.endedUnknown, "未知状态"),
                (["COMPLETED"], HistoryEntry.endedUnknown, "记录不全"),
                ([String](), HistoryEntry.endedUnknown, "没有记录"),
                (["COMPLETED", "COMPLETED"], "COMPLETED", "全部完成"),
                (["FAILED"], "FAILED", "明确失败"),
            ] {
                let finals = Parsers.sacct(states.enumerated().map { "500_\($0.offset + 1)|scan|\($0.element)|00:01:00|0:0" })
                engine.recordEndedWhileAway(host: a, gone: gone, finals: finals)
                results.items.append((engine.history.entries(for: a.id).first?.state == expected && events.isEmpty,
                                      "数组补记：\(label)时状态正确且不弹提醒"))
            }
            // 老版本 active-jobs.json 没有 arrayTotal，仍能读取，但不能据此确认数组整体成功。
            do {
                let legacy = Data(#"{"id":"500","name":"scan","slurm":true,"seenAt":"2026-01-01T00:00:00Z"}"#.utf8)
                var old = try JSONDecoder.iso.decode(HistoryStore.ActiveJob.self, from: legacy)
                old.seenAt = Date()
                engine.recordEndedWhileAway(host: a, gone: [old],
                                            finals: Parsers.sacct(["500_1|scan|COMPLETED|00:01:00|0:0"]))
                results.items.append((old.arrayTotal == nil && engine.history.entries(for: a.id).first?.state == HistoryEntry.endedUnknown,
                                      "数组补记：旧记录没有总数时保守记为结果未知"))
            } catch { results.items.append((false, "数组补记：旧记录兼容失败：\(error)")) }

            // 关注：只提醒关注的任务时，没关注的任务结束不提醒；关注的任务结束后自动取消关注
            events = []
            let f = host(.direct)
            let two = ["4242 100 50.0 1000 python train.py", "4343 100 50.0 1000 python eval.py"]
            await ingest(f, [("procs", 0, two)])
            if let j = engine.snapshots[f.id]?.jobs.first(where: { $0.id == "4242" }) { engine.toggleStar(hostID: f.id, job: j) }
            store.settings.alertScope = .starred
            await ingest(f, [("procs", 0, [])])
            results.items.append((events.count == 1 && events.first?.jobID == "4242", "关注：只提醒关注的任务时，没关注的任务结束不提醒"))
            results.items.append((!store.settings.starredJobs.contains { $0.hostID == f.id }, "关注：任务结束后自动取消关注"))
            // 列表没读全时不取消关注
            await ingest(f, [("procs", 0, two)])
            if let j = engine.snapshots[f.id]?.jobs.first(where: { $0.id == "4343" }) { engine.toggleStar(hostID: f.id, job: j) }
            await ingest(f, [("procs", 1, [])])
            results.items.append((engine.isStarred(f.id, "4343"), "关注：进程列表出错时不取消关注"))
            // 种类开关：关掉“完成”后，关注的任务结束也不提醒
            events = []
            store.settings.alertFinished = false
            await ingest(f, [("procs", 0, [])])
            results.items.append((events.isEmpty, "提醒设置：关掉“完成”后不提醒结束"))
            store.settings.alertFinished = true
            store.settings.alertScope = .all
            // 数组：关注的是整个数组（主编号）
            let sa = host(.slurm)
            await ingest(sa, [("squeue", 0, ["700_1|scan|RUNNING|0:10|1:00:00|1|cn01|cpu|700|1", "700_[2-5]|scan|PENDING|0:00|1:00:00|1|(Priority)|cpu|700|[2-5]"])])
            if let g = engine.snapshots[sa.id]?.jobs.first { engine.toggleStar(hostID: sa.id, job: g) }
            results.items.append((store.settings.starredJobs.last?.jobID == "700" && engine.isStarred(sa.id, "700"), "关注：数组作业按主编号关注"))
            // 远端列表失败时仍保持本地 Action 的最新状态，不因沿用快照重复追加。
            let localHost = host(.direct)
            var local = RemoteJob(id: "local:merge-test", name: "Deploy", state: .running, source: .progressFile)
            engine.localJobs[localHost.id] = [local]
            await ingest(localHost, [("procs", 0, [py])])
            local.state = .completed
            engine.localJobs[localHost.id] = [local]
            await ingest(localHost, [("procs", 1, [])])
            results.items.append((engine.snapshots[localHost.id]?.jobs.filter { $0.id == local.id }.count == 1
                                  && engine.snapshots[localHost.id]?.jobs.first { $0.id == local.id }?.state == .completed
                                  && engine.snapshots[localHost.id]?.jobs.contains { $0.id == "4242" } == true,
                                  "v0.4.0 合并：远端失败沿用进程，本地 Action 仍更新且不重复"))
            sem.signal()
        }
        while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return results.items
    }
}
