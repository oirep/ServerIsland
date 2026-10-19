import Foundation
import AppKit

/// 只使用临时目录与本机假脚本，绝不连接真实 SSH 或执行部署。
@MainActor
enum SelfTestActions {
    static func run(_ check: (Bool, String) -> Void) {
        let edit = EditMenu.make()
        check(edit.items.contains { $0.keyEquivalent == "v" && $0.action == Selector("paste:")
              && $0.target == nil }, "编辑快捷键：⌘V 通过 responder chain 转交给当前文本编辑器")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-actions-test-" + UUID().uuidString)
        let directory = root.appendingPathComponent("local/progress")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldEnv = ProcessInfo.processInfo.environment["SERVERISLAND_LOCAL_STATE_DIR"]
        setenv("SERVERISLAND_LOCAL_STATE_DIR", root.path, 1)
        defer {
            if let oldEnv { setenv("SERVERISLAND_LOCAL_STATE_DIR", oldEnv, 1) }
            else { unsetenv("SERVERISLAND_LOCAL_STATE_DIR") }
        }

        let legacy = try? JSONDecoder().decode(HostConfig.self, from: Data(#"{"alias":"demo-host"}"#.utf8))
        let oldSettings = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        check(oldSettings?.progressFileStaySeconds == 0, "停留时长：旧配置默认 0，永久显示")
        let clock = Date()
        var terminal = RemoteJob(id: "local:duration-test", name: "测试", state: .completed, source: .progressFile)
        terminal.progressEndedAt = clock.addingTimeInterval(-30)
        check(terminal.staysVisible(seconds: 0, now: clock)
              && terminal.staysVisible(seconds: 31, now: clock)
              && !terminal.staysVisible(seconds: 30, now: clock), "停留时长：0 永久，非零按结束时刻准确到期")
        terminal.state = .failed
        let failedHides = !terminal.staysVisible(seconds: 10, now: clock)
        terminal.state = .other
        check(failedHides && !terminal.staysVisible(seconds: 10, now: clock), "停留时长：失败与异常退出同样生效")
        terminal.state = .running
        check(terminal.staysVisible(seconds: 1, now: clock), "停留时长：不隐藏正在运行的任务")
        terminal.state = .failed; terminal.source = .slurm
        check(terminal.staysVisible(seconds: 1, now: clock), "停留时长：不改变调度系统任务的显示")
        check(legacy?.actions.isEmpty == true, "Action：旧服务器配置缺少 actions 时仍可读取")
        var host = HostConfig(alias: "demo-host", displayName: "演示服务器")
        let action = HostAction(name: "模拟部署", command: "echo '同步代码'\necho '构建后端镜像'\nsleep 0.4\nexit 0", target: .local)
        host.actions = [action]
        let encoded = try? JSONEncoder().encode(host)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(decoded?.actions == host.actions, "Action：名称、脚本、执行位置和标识可完整保存")
        check(!HostAction(name: "缺脚本").isValid && action.isValid, "Action：未填写执行内容不能触发")
        let oldAction = try? JSONDecoder().decode(HostAction.self,
            from: Data(#"{"name":"旧任务","command":"true","target":"local"}"#.utf8))
        check(oldAction?.enabled == true, "Action 启用：旧配置缺少 enabled 时默认启用")
        var fileRule = ProgressRule()
        fileRule.name = "文件日志"; fileRule.file = "train.log"; fileRule.pattern = "epoch"
        var logRule = ProgressRule()
        logRule.source = .actionLog; logRule.match = .regex; logRule.name = "部署日志"
        logRule.pattern = #"^\[进度\s+(\d+)/(\d+)\]\s*(.+)$"#
        let pack = ProgressRulePack(rules: [fileRule, logRule])
        let roundtrip = try? ProgressRulePack.decode(pack.data())
        check(roundtrip?.rules == pack.rules, "识别规则包：文件与部署规则批量导入导出，顺序和字段不丢失")
        check(logRule.isLogUsable && !logRule.isUsable && fileRule.isUsable,
              "识别规则包：部署日志规则不会进入服务器文件检测器")
        if let roundtrip {
            check(roundtrip.merging(into: [fileRule]).count == 2,
                  "识别规则包：重复导入按标识更新，不重复添加")
        }
        var invalid = logRule; invalid.pattern = "("
        check((try? ProgressRulePack.decode(ProgressRulePack(rules: [invalid]).data())) == nil,
              "识别规则包：无效正则整包拒绝导入")
        let presetURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("examples/deployment-progress-rules.json")
        if let data = try? Data(contentsOf: presetURL) {
            let presets = try? ProgressRulePack.decode(data)
            check(presets?.rules.count == 3 && presets?.rules.allSatisfy(\.isLogUsable) == true,
                  "识别规则包：生成的三类部署日志模板可直接导入")
        }
        var disabled = action
        disabled.enabled = false
        var ordering = HostConfig(alias: "demo-ordering")
        let first = HostAction(name: "第一个", command: "true")
        let last = HostAction(name: "最后一个", command: "true")
        ordering.actions = [first, disabled, last]
        ordering.actions.swapAt(0, 2)
        check(ordering.enabledActions.map(\.id) == [last.id, first.id],
              "Action 顺序：移动后保留标识，刘海按顺序过滤禁用项")
        let savedOrdering = try? JSONEncoder().encode(ordering)
        let loadedOrdering = savedOrdering.flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(loadedOrdering?.actions == ordering.actions, "Action 配置：顺序和启用状态持久保存")
        let editor = PlainScriptEditor.makeTextView()
        // insertText 会注册系统输入上下文；命令行自检不依赖窗口服务，实际输入由安装后的 App 验证。
        check(!editor.isRichText && !editor.isAutomaticQuoteSubstitutionEnabled
              && !editor.isAutomaticDashSubstitutionEnabled && !editor.isAutomaticTextReplacementEnabled
              && !editor.isAutomaticSpellingCorrectionEnabled,
              "脚本编辑：纯文本输入，关闭智能引号、破折号、自动替换和纠错")

        let run = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let file = directory.appendingPathComponent("deploy-test.json")
        func write(_ status: String, hostID: String = "") {
            let value: [String: Any] = [
                "name": "演示任务", "status": status, "message": status == "unknown" ? "连接中断，远端结果未知" : "模拟进度",
                "updated": Date().timeIntervalSince1970,
                "deployment": ["local": true, "run_id": run, "host": hostID,
                               "action_id": action.id.uuidString, "pid": getpid(),
                               "started": Date().timeIntervalSince1970]
            ]
            if let data = try? JSONSerialization.data(withJSONObject: value) { try? data.write(to: file, options: .atomic) }
        }
        write("running", hostID: host.alias)
        let records = LocalTaskStore.read(from: directory)
        check(records.count == 1 && LocalTaskStore.hostID(for: records[0], hosts: [host]) == host.id,
              "本机任务：SSH 别名归属到对应服务器")
        write("unknown", hostID: host.id.uuidString.lowercased())
        let unknown = LocalTaskStore.read(from: directory)
        check(unknown.first?.job.state == .other
              && LocalTaskStore.hostID(for: unknown[0], hosts: [host]) == host.id,
              "本机任务：UUID 归属不区分大小写，断连显示结果未知")
        try? Data("not json".utf8).write(to: directory.appendingPathComponent("bad.json"))
        try? Data(repeating: 32, count: 5000).write(to: directory.appendingPathComponent("huge.json"))
        check(LocalTaskStore.read(from: directory).count == 1, "本机任务：坏文件与超过 4 KB 的文件不影响其它任务")
        write("running", hostID: host.alias)
        let store = ConfigStore(persist: false)
        store.settings.hosts = [host]
        store.settings.islandAlerts = false; store.settings.soundEnabled = false
        store.settings.systemNotifications = false
        let engine = MonitorEngine(store: store)
        engine.runHostAction(host: host, action: disabled)
        check(engine.runningActions.isEmpty, "Action 启用：禁用项不能启动执行")
        engine.runHostAction(host: host, action: HostAction(name: "缺少命令"), testRun: true)
        check(engine.runningActions.isEmpty, "Action 测试：未启用仍可测试，但空脚本不能执行")
        var snap = HostSnapshot()
        snap.health = .error("模拟 SSH 不可用")
        snap.metrics.cpuPercent = 42
        engine.setSnapshot(snap, for: host.id)
        engine.refreshLocalTasks(from: directory)
        check(engine.actionIsRunning(host: host, action: action),
              "Action：通过 CLI 用 SSH 别名归属的同一任务也会禁用运行按钮")
        check(engine.snapshots[host.id]?.jobs.count == 1 && engine.snapshots[host.id]?.metrics.cpuPercent == 42,
              "本机任务：合并时保留服务器指标，不依赖 SSH 查询成功")
        let parts = IslandLayout.parts(host, engine.snapshots[host.id]!)
        check(parts.actions && parts.metrics && parts.problem && parts.jobRows == 1,
              "Action 布局：连接异常时仍显示按钮和本机运行进度")
        check(!IslandLayout.isIdle(host, HostSnapshot()), "Action 布局：带快捷操作的服务器不折叠为空闲行")
        var disconnected = snap
        disconnected.jobs = [RemoteJob(id: "1234", name: "旧远端进程", state: .running, source: .process)]
        check(IslandLayout.parts(host, disconnected).jobRows == 0,
              "Action 布局：SSH 异常不会把旧远端进程作为最新任务展示")
        var events = 0
        engine.onEvent = { _ in events += 1 }
        write("done", hostID: host.id.uuidString)
        engine.refreshLocalTasks(from: directory)
        engine.refreshLocalTasks(from: directory)
        check(events == 1, "本机任务：终态仅通知一次，不被远端轮询重复处理")
        store.settings.progressFileStaySeconds = 1
        check(engine.displaySnapshot(host.id, now: Date().addingTimeInterval(5)).jobs.isEmpty
              && engine.snapshots[host.id]?.jobs.count == 1, "停留时长：只隐藏展示，不删除快照或触发重复结束")
        store.settings.progressFileStaySeconds = 0
        check(engine.displaySnapshot(host.id, now: Date().addingTimeInterval(5)).jobs.count == 1,
              "停留时长：切回 0 可恢复已有任务显示")

        // 真实启动一次本地 Action，检查 stdin 脚本、包装器、文件采集和重复点击保护。
        try? FileManager.default.removeItem(at: file)
        var runtimeRule = logRule
        runtimeRule.logMode = .stages
        runtimeRule.stages = [.init(name: "取代码", pattern: "^同步代码$"),
                              .init(name: "做镜像", pattern: "^构建后端镜像$")]
        store.settings.progressRules = [runtimeRule]
        engine.runHostAction(host: host, action: disabled, testRun: true)
        engine.runHostAction(host: host, action: disabled, testRun: true)
        let deadline = Date().addingTimeInterval(8)
        while !engine.runningActions.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        }
        let launched = LocalTaskStore.read(from: directory).filter { $0.actionID == action.id.uuidString }
        check(launched.count == 1 && launched.first?.job.state == .completed,
              "Action：禁用项可通过测试执行本机 Bash，进度归属正确，重复点击不启动第二份任务")
        check(!disabled.enabled, "Action：测试执行不会自动开启快捷入口")
        check(launched.first?.job.message?.contains("部署完成") == true && engine.runningActions.isEmpty,
              "Action：脚本退出后更新完成状态并恢复按钮")
        if let record = launched.first {
            let metadataURL = root.appendingPathComponent("local/deployments/" + record.job.id.dropFirst(6) + ".json")
            let metadata = (try? Data(contentsOf: metadataURL)).flatMap {
                (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
            }
            check((metadata?["deployment"] as? [String: Any])?["source"] as? String == "rule",
                  "识别规则包：实际 Action 从设置快照读取规则，不依赖包装器业务代码")
            let detail = LocalTaskStore.detail(for: record.job, from: directory)
            check(detail.stdout.lines.contains { $0.contains("构建后端镜像") },
                  "Action 详情：读取本机保存的阶段记录与脚本输出")
            check(detail.fields.contains { $0.0 == "完成时间" && $0.1.count >= 19 },
                  "Action 详情：完成后保留具体年月日时分秒")
        } else { check(false, "Action 详情：缺少任务记录") }
    }
}
