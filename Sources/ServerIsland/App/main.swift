import AppKit

let arguments = CommandLine.arguments

// 作为 ssh 的 SSH_ASKPASS 被调用：弹出密码框，结果写到 stdout。
if AskPass.isAskPassInvocation {
    exit(MainActor.assumeIsolated { AskPass.run() })
}

// 开发用：把各个状态的刘海渲染成 PNG（不需要屏幕录制权限）。
//   ServerIsland --render-preview <输出目录> [zh|en]（默认中文）
if let i = arguments.firstIndex(of: "--render-preview"), i + 1 < arguments.count {
    let lang: AppLanguage = i + 2 < arguments.count && arguments[i + 2] == "en" ? .en : .zh
    MainActor.assumeIsolated {
        PreviewRenderer.render(to: arguments[i + 1], language: lang)
    }
    exit(0)
}

// 开发用：检查 GitHub 上的最新版本。  ServerIsland --check-update [假装的当前版本]
if let i = arguments.firstIndex(of: "--check-update") {
    if i + 1 < arguments.count { UpdateChecker.versionOverride = arguments[i + 1] }
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        _ = await UpdateChecker.shared.check()
        switch UpdateChecker.shared.state {
        case .available(let r): print("有新版本 \(r.version)\n  下载：\(r.downloadURL)\n  页面：\(r.pageURL)\n  说明：\(r.notes)")
        case .upToDate(let v): print("已是最新（GitHub 最新 \(v)）")
        case .failed(let m): print("失败：\(m)")
        default: print(UpdateChecker.shared.state)
        }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// 开发用：导出远端脚本，和 Windows / Linux 版逐字比较（见 references/cross-platform.md）。
if let i = arguments.firstIndex(of: "--dump-scripts"), i + 1 < arguments.count {
    let dir = URL(fileURLWithPath: arguments[i + 1])
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for (name, text) in MainActor.assumeIsolated({ ReferenceScripts.all() }) {
        try? text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    print("ok")
    exit(0)
}

if arguments.contains("--selftest") {
    exit(SelfTest.run() ? 0 : 1)
}

// 开发用：对一台主机执行一次完整采集，打印原始输出和解析结果。
//   ServerIsland --diagnose <ssh别名> [slurm|direct]
if let i = arguments.firstIndex(of: "--diagnose"), i + 1 < arguments.count {
    let kindArg = i + 2 < arguments.count ? arguments[i + 2] : "direct"
    let kind = HostKind(rawValue: kindArg.replacingOccurrences(of: "+", with: "")) ?? .direct
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        await SelfTest.diagnose(alias: arguments[i + 1], kind: kind, alsoProcesses: kindArg.hasSuffix("+"))
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// 开发用：查看某个进程的详情和日志末尾（只读）。
//   ServerIsland --detail <ssh别名> <pid>
if let i = arguments.firstIndex(of: "--detail"), i + 2 < arguments.count {
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let engine = MonitorEngine(store: ConfigStore(persist: false))
        let d = await engine.fetchDetail(host: HostConfig(alias: arguments[i + 1]),
                                         job: RemoteJob(id: arguments[i + 2], name: "", state: .running, source: .process))
        for (k, v) in d.fields { print(k, "=", v) }
        print("stdout:", d.stdout.path ?? "-", d.stdout.note ?? "")
        d.stdout.lines.suffix(6).forEach { print("  |", $0) }
        print("stderr:", d.stderr?.path ?? "（与 stdout 相同或无）")
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// 开发用：查询 Slurm 分区空闲资源（只读）。  ServerIsland --partitions <ssh别名>
if let i = arguments.firstIndex(of: "--partitions"), i + 1 < arguments.count {
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let engine = MonitorEngine(store: ConfigStore(persist: false))
        let r = await engine.fetchPartitions(host: HostConfig(alias: arguments[i + 1], kind: .slurm))
        if let e = r.error { print("error:", e) }
        for p in r.stats ?? [] {
            print(p.name, p.isDefault ? "*" : "", p.available ? "up" : "DOWN", p.timeLimit,
                  "\(p.gpuLabel) \(p.gpuIdle)/\(p.gpuTotal)", "CPU \(p.cpuIdle)/\(p.cpuTotal)",
                  "nodes idle \(p.idleNodes) mix \(p.mixNodes) alloc \(p.allocNodes) down \(p.downNodes)/\(p.nodes)", p.gpuModels.sorted())
        }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

// 开发用：读取某个目录的计算软件最终状态。  ServerIsland --final-state <ssh别名> <目录>
// --curve <别名> <目录> [gnep|vasp]：读取详情页曲线（两次，第二次应是增量、没有新行）
if let i = arguments.firstIndex(of: "--curve"), i + 2 < arguments.count {
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let host = HostConfig(alias: arguments[i + 1])
        let mode = i + 3 < arguments.count ? arguments[i + 3] : "nep"
        var app = AppProgress(kind: mode == "gnep" ? .gnep : (mode == "vasp" ? .vasp : .nep), dir: arguments[i + 2])
        if mode == "vasp" { app.vaspMode = .relax }
        for src in AppCurves.sources(for: app) {
        print("== \(src.path)")
        var cache = CurveCache()
        for round in 1...2 {
            let script = AppCurves.script(src, offset: cache.lineCount, head: cache.head)
            let t0 = Date()
            let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 20)
            let rows = r.stdout.components(separatedBy: "\n").filter { $0.hasPrefix("row=") }.count
            guard let merged = AppCurves.merge(r.stdout, into: cache) else { print("读不到", r.stdout, r.stderr); break }
            cache = merged
            print("第 \(round) 次：文件 \(cache.lineCount) 行，本次传回 \(rows) 行，累计 \(cache.rows.count) 行，\(r.stdout.utf8.count) 字节，\(String(format: "%.2fs", Date().timeIntervalSince(t0)))")
        }
        if let c = AppCurves.curve(src, rows: cache.rows, extra: cache.extra) {
            for s in c.series { print(" ", s.name, s.points.count, "点，最后", s.points.last.map { "\($0.x) → \($0.y)" } ?? "-") }
            if let t = c.threshold { print("  目标", t) }
            if let n = c.note { print("  说明", n) }
        }
        }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

if let i = arguments.firstIndex(of: "--final-state"), i + 2 < arguments.count {
    let sem = DispatchSemaphore(value: 0)
    Task { @MainActor in
        let host = HostConfig(alias: arguments[i + 1])
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: AppDetectors.finalStateScript(id: "x", dir: arguments[i + 2]), timeout: 15)
        if let a = AppDetectors.parse(r.stdout.components(separatedBy: "\n"))["x"] {
            print(a.title, a.summary, "finished:", a.finished)
        } else { print("未识别", r.stdout, r.stderr) }
        sem.signal()
    }
    while sem.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(0)
}

let demo = arguments.contains("--demo") || ProcessInfo.processInfo.environment["SERVERISLAND_DEMO"] == "1"

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = MainActor.assumeIsolated { AppDelegate(demo: demo) }
app.delegate = delegate
app.run()
