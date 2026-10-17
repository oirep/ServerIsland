import AppKit
import SwiftUI

/// `--render-preview <dir>`：用演示数据把各状态渲染成 PNG，便于检查视觉效果。
@MainActor
enum PreviewRenderer {
    static func render(to dir: String, language: AppLanguage = .zh) {
        let url = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        IslandPreview.active = true
        // SI_BARE=1：所有刘海和页面截图都不画桌面（README 截图用，见 scripts/readme_assets.sh）
        let bareAll = ProcessInfo.processInfo.environment["SI_BARE"] == "1"

        let store = ConfigStore(persist: false)
        store.settings.language = language
        store.settings = DemoData.settings()
        store.settings.language = language
        let engine = MonitorEngine(store: store, demo: true)
        for host in store.settings.hosts {
            engine.setPreviewSnapshot(DemoData.snapshot(for: host, tick: 3, previous: HostSnapshot()), for: host.id)
        }
        // 第二台机器演示"需要登录"的状态。
        var login = HostConfig(alias: "lab-old", displayName: "旧集群", kind: .slurm)
        login.auth = .interactive
        let geometry = NotchGeometry(notchWidth: 185, notchHeight: 32, hasNotch: true,
                                     screenFrame: NSRect(x: 0, y: 0, width: 1512, height: 982))

        /// bare：不画桌面，只留黑色的岛（透明背景），README 截图用，之后裁掉透明边。
        func shot(_ name: String, hovering: Bool, width: CGFloat = 820, height: CGFloat, bare: Bool = false) {
            let vm = IslandViewModel()
            vm.geometry = geometry
            vm.hovering = hovering
            let view = ZStack(alignment: .top) {
                if !(bare || bareAll) { Desktop(notchWidth: geometry.notchWidth, notchHeight: geometry.notchHeight) }
                IslandRootView(vm: vm, engine: engine, store: store)
            }
            .frame(width: width, height: height)
            .transaction { $0.disablesAnimations = true }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            if let img = renderer.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url.appendingPathComponent(name + ".png"))
                print("wrote \(name).png")
            }
        }

        // 宠物表情一览
        let pets = HStack(spacing: 28) {
            ForEach([PetMood.idle, .working, .waiting, .happy, .sad, .worried], id: \.self) { m in
                VStack(spacing: 10) {
                    PetView(mood: m, size: 56, animated: false)
                    Text("\(String(describing: m))").font(.system(size: 12, design: .monospaced)).foregroundStyle(.white.opacity(0.6))
                }
            }
        }
        .padding(30).background(Color.black)
        let pr = ImageRenderer(content: pets); pr.scale = 2
        if let img = pr.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: url.appendingPathComponent("pets.png"))
        }

        shot("collapsed", hovering: false, height: 120)
        engine.currentEvent = IslandEvent(kind: .finished, title: L("NEP 训练完成", "NEP training finished"),
                                          subtitle: L("20,000 代 · nep-train", "20,000 gen · nep-train"),
                                          hostName: L("4090 工作站", "4090 Workstation"))
        shot("toast", hovering: false, height: 150)
        engine.currentEvent = IslandEvent(kind: .failed, title: L("aimd_LGPS_1200K 超时", "aimd_LGPS_1200K timed out"),
                                          subtitle: L("Timeout · 用时 48:00:00", "Timeout · took 48:00:00"),
                                          hostName: L("HPC 集群", "HPC Cluster"))
        shot("toast-failed", hovering: false, height: 150)
        engine.currentEvent = nil
        shot("expanded", hovering: true, height: 560)

        // README 动图用的三帧：同一尺寸的 收起 → 完成提示 → 展开（scripts/readme_gif.sh 拼成 GIF）
        shot("gif-1-collapsed", hovering: false, height: 560)
        engine.currentEvent = IslandEvent(kind: .finished, title: L("NEP 训练完成", "NEP training finished"),
                                          subtitle: L("20,000 代 · nep-train", "20,000 gen · nep-train"),
                                          hostName: L("4090 工作站", "4090 Workstation"))
        shot("gif-2-toast", hovering: false, height: 560)
        engine.currentEvent = nil
        shot("gif-3-expanded", hovering: true, height: 560)

        // 二级页面
        func page(_ name: String, _ content: some View, bare: Bool = false) {
            let g = geometry
            let w = IslandLayout.spec(mode: .expanded, geometry: g, contentHeight: IslandLayout.pageHeight).size.width
            let v = ZStack(alignment: .top) {
                if !(bare || bareAll) { Desktop(notchWidth: g.notchWidth, notchHeight: g.notchHeight) }
                VStack(spacing: 0) {
                    Color.clear.frame(height: g.notchHeight + IslandLayout.topGap)
                    content.frame(height: IslandLayout.pageHeight)
                    Color.clear.frame(height: IslandLayout.bottomPad)
                }
                .padding(.horizontal, IslandLayout.sidePad + 14)
                .frame(width: w)
                .background(NotchShape(topRadius: 14, bottomRadius: 26).fill(Color.black))
            }
            .frame(width: 820, height: g.notchHeight + IslandLayout.pageHeight + 60)
            .environment(\.colorScheme, .dark)
            let r = ImageRenderer(content: v); r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url.appendingPathComponent(name + ".png"))
            }
        }
        var slurmHost = store.settings.hosts[0]; slurmHost.allowCancel = true
        let job = engine.snapshots[slurmHost.id]!.jobs[0]
        var detail = JobDetail()
        let dir = DemoData.home + "/Li3PS4/aimd-900K"
        detail.fields = [(L("状态", "State"), "RUNNING"), (L("已运行", "Elapsed"), "10:07:00"), (L("时间上限", "Time limit"), "2-00:00:00"),
                         (L("分区", "Partition"), "cpu"), (L("节点", "Nodes"), "cn[012-013]"),
                         (L("资源", "Resources"), "cpu=128,mem=480G,node=2"), (L("工作目录", "Directory"), dir)]
        detail.stdout.path = dir + "/slurm-8812044.out"
        var vaspLog: [String] = []
        for step in 1238...1240 {
            vaspLog += ["       N       E                     dE             d eps       ncg     rms          rms(c)",
                        "RMM:   1    -0.51234\(step % 7)E+03   -0.21E-02   -0.34E-03  1520   0.62E-01",
                        "RMM:   2    -0.51235\(step % 5)E+03   -0.32E-04   -0.12E-04   980   0.11E-01    0.45E-02",
                        "RMM:   3    -0.51235\(step % 9)E+03   -0.48E-06   -0.21E-06   960   0.17E-02",
                        String(format: "%5d T=  %4d. E= -.4987%04dE+03 F= -.5123%04dE+03 E0= -.5123%04dE+03  EK= 0.13358E+02 SP= 0.00E+00 SK= 0.00E+00",
                               step, 890 + step % 23, step % 9973, step % 9871, step % 9871),
                        "bond charge predicted"]
        }
        detail.stdout.lines = Array(vaspLog.suffix(8))
        detail.stderr = .init(path: dir + "/slurm-8812044.err", lines: [])
        page("detail", JobDetailPage(host: slurmHost, job: job, sampledAt: Date(), stillListed: true, engine: engine,
                                     onBack: {}, openSettings: {}, preloaded: detail))
        page("detail-confirm", JobDetailPage(host: slurmHost, job: job, sampledAt: Date(), stillListed: true, engine: engine,
                                             onBack: {}, openSettings: {}, preloaded: detail, previewStage: .confirm(force: false)))
        let now = Date()
        page("history", HistoryPage(host: slurmHost, engine: engine, onBack: {}, preloaded: [
            HistoryEntry(id: "8811990", name: "relax_Li3PS4_pbe", state: "COMPLETED", elapsed: 7_412, endedAt: now.addingTimeInterval(-1_800), exitCode: "0:0"),
            HistoryEntry(id: "8811987", name: "phonon_LiCoO2_222", state: "OUT_OF_MEMORY", elapsed: 2_538, endedAt: now.addingTimeInterval(-5_400), exitCode: "0:125"),
            HistoryEntry(id: "8811950", name: "scf_LiCoO2_kmesh", state: "COMPLETED", elapsed: 3_301, endedAt: now.addingTimeInterval(-14_000), exitCode: "0:0"),
            HistoryEntry(id: "8811901", name: "neb_Li_vacancy", state: "CANCELLED by 1000", elapsed: 412, endedAt: now.addingTimeInterval(-30_000), exitCode: "0:15"),
            HistoryEntry(id: "8811877", name: "aimd_LGPS_1200K", state: "TIMEOUT", elapsed: 172_800, endedAt: now.addingTimeInterval(-60_000), exitCode: "0:0"),
        ]))

        // 设置窗口（离屏窗口 + cacheDisplay，不需要屏幕录制权限）
        func settingsShot(_ name: String, _ page: SettingsPage, dark: Bool) {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 640), styleMask: [.titled, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            w.titlebarAppearsTransparent = true
            let hv = NSHostingView(rootView: SettingsView(store: store, engine: engine, initial: page))
            w.contentView = hv
            w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
            w.orderFrontRegardless()
            for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
            hv.layoutSubtreeIfNeeded()
            if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
                hv.cacheDisplay(in: hv.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(name + ".png"))
            }
            w.orderOut(nil)
        }
        store.settings.hosts[0].auth = .interactive
        settingsShot("settings-general", .general, dark: true)
        settingsShot("settings-host", .host(store.settings.hosts[0].id), dark: true)
        settingsShot("settings-host-light", .host(store.settings.hosts[1].id), dark: false)
        store.settings.language = .en
        settingsShot("settings-host-en", .host(store.settings.hosts[1].id), dark: true)
        shot("expanded-en", hovering: true, height: 560)
        store.settings.language = language

        page("partitions", PartitionsPage(host: slurmHost, engine: engine, onBack: {}, preloaded: [
            PartitionStat(name: "cpu", isDefault: true, available: true, timeLimit: "7-00:00:00", nodes: 120, idleNodes: 18, mixNodes: 22,
                          allocNodes: 78, downNodes: 2, cpuIdle: 2_960, cpuTotal: 15_360),
            PartitionStat(name: "gpu-v100", available: true, timeLimit: "3-00:00:00", nodes: 24, idleNodes: 2, mixNodes: 6, allocNodes: 16,
                          cpuIdle: 210, cpuTotal: 1_152, gpuIdle: 19, gpuTotal: 96, gpuModels: ["V100-SXM2"]),
            PartitionStat(name: "gpu-a100", available: true, timeLimit: "2-00:00:00", nodes: 8, mixNodes: 3, allocNodes: 5,
                          cpuIdle: 64, cpuTotal: 512, gpuIdle: 5, gpuTotal: 64, gpuModels: ["A100-SXM4"]),
            PartitionStat(name: "bigmem", available: true, timeLimit: "7-00:00:00", nodes: 4, idleNodes: 3, allocNodes: 1,
                          cpuIdle: 384, cpuTotal: 512),
            PartitionStat(name: "debug", available: true, timeLimit: "00:30:00", nodes: 2, idleNodes: 2, cpuIdle: 128, cpuTotal: 128),
        ]))
        // 打开"允许取消"：否则底部的"去设置"链接按钮在离屏渲染里画不出来（显示成黄色方块）
        var nepHost = store.settings.hosts[1]; nepHost.allowCancel = true
        if let nepJob = engine.snapshots[nepHost.id]?.jobs.first {
            // 模拟一条下降的 loss 曲线（带一点波动）
            // 只画到当前的 7,800 代，末尾的值和上方的 Loss 字段一致
            let rows: [[Double]] = (1...78).map { k in
                let g = Double(k * 100), d = exp(-Double(k) / 14)
                let wob = 1 + 0.03 * sin(Double(k) * 0.9) * (1 - Double(k) / 90)
                return [g, (0.1808 + 0.8 * d) * wob, 0, 0, (0.00071 + 0.02 * d) * wob, (0.0705 + 0.35 * d) * wob, (0.01112 + 0.05 * d) * wob]
            }
            // NEP 的屏幕输出（每 100 代一行）
            var nepDetail = JobDetail()
            nepDetail.stdout.path = DemoData.home + "/Li3PS4/nep-train/nep.log"
            nepDetail.stdout.lines = ["Step     Total-Loss  L1Reg-Loss  L2Reg-Loss  RMSE-E-Train  RMSE-F-Train  RMSE-V-Train"]
                + (0..<5).map { k -> String in
                    let gen = 7_400 + k * 100, d = Double(4 - k) * 0.0006
                    return String(format: "%-8d %10.5f  %10.5f  %10.5f  %12.5f  %12.5f  %12.5f",
                                  gen, 0.1815 + d, 0.0451 + d / 9, 0.0647 + d / 7, 0.00074 + d / 60, 0.07098 + d / 2, 0.01131 + d / 8)
                }
            page("detail-nep", JobDetailPage(host: nepHost, job: nepJob, sampledAt: Date(), stillListed: true, engine: engine,
                                             onBack: {}, openSettings: {}, preloaded: nepDetail,
                                             preloadedCurve: AppCurves.curve(.loss(path: "", gnep: false), rows: rows)))
            var relaxApp = AppProgress(kind: .vasp, dir: DemoData.home + "/LiCoO2/relax-hse"); relaxApp.vaspMode = .relax; relaxApp.current = 23
            var relaxJob = RemoteJob(id: "31022", name: "vasp_std", state: .running, source: .process)
            relaxJob.app = relaxApp; relaxJob.message = relaxApp.title + " · " + relaxApp.summary
            let eRows: [[Double]] = (1...23).map { k in [Double(k), -432.1 - 3.2 * (1 - exp(-Double(k) / 5))] }
            page("detail-vasp", JobDetailPage(host: nepHost, job: relaxJob, sampledAt: Date(), stillListed: true, engine: engine,
                                              onBack: {}, openSettings: {}, preloaded: JobDetail(),
                                              preloadedCurve: AppCurves.curve(.vaspEnergy(path: ""), rows: eRows)))
        }

        store.settings.hosts[1].muted = true
        store.settings.hosts[1].paused = true
        store.settings.hosts.append(login)
        engine.setPreviewSnapshot(HostSnapshot(health: .needsLogin("需要登录（点“登录…”输入密码 / 动态口令）")), for: login.id)
        shot("expanded-login", hovering: true, height: 640)

        // 合并空闲的服务器：两台没有任务的机器折叠成一行
        store.settings.hosts.removeAll { $0.id == login.id }
        store.settings.hosts[1].muted = false
        store.settings.hosts[1].paused = false
        for (alias, name, cpu) in [("idle-a", "老服务器", 3.0), ("idle-b", "3090 工作站", 1.0)] {
            let h = HostConfig(alias: alias, displayName: name, kind: .direct)
            store.settings.hosts.append(h)
            var s = HostSnapshot(health: .ok, lastUpdate: Date())
            s.metrics.cpuPercent = cpu
            engine.setPreviewSnapshot(s, for: h.id)
        }
        shot("expanded-idle", hovering: true, height: 640)

        // VASP / LAMMPS 识别结果
        let gpuBox = store.settings.hosts[1]
        if var snap = engine.snapshots[gpuBox.id] {
            func appJob(_ id: String, _ name: String, _ app: AppProgress, elapsed: Double) -> RemoteJob {
                var j = RemoteJob(id: id, name: name, state: .running, source: .process)
                j.app = app; j.progress = app.fraction; j.eta = app.eta; j.elapsed = elapsed
                j.message = app.title + " · " + app.summary
                return j
            }
            var relax = AppProgress(kind: .vasp, dir: DemoData.home + "/LiCoO2/relax-hse"); relax.vaspMode = .relax; relax.current = 23
            var vmd = AppProgress(kind: .vasp, dir: DemoData.home + "/Li3PS4/aimd-900K"); vmd.vaspMode = .md; vmd.current = 1_200; vmd.total = 5_000; vmd.hasTarget = true
            var lmp = AppProgress(kind: .lammps, dir: DemoData.home + "/HEA/npt-1200K"); lmp.current = 380_000; lmp.total = 1_000_000; lmp.rate = 830
            var custom = AppProgress(kind: .custom, dir: DemoData.home + "/MACE/run-02"); custom.customName = L("训练", "Training")
            custom.customUnit = "epoch"; custom.current = 37; custom.total = 100
            snap.jobs = [appJob("31022", "vasp_std", relax, elapsed: 5_400), appJob("31877", "vasp_std", vmd, elapsed: 9_000),
                         appJob("32001", "lmp", lmp, elapsed: 2_300), appJob("32456", "python train.py", custom, elapsed: 7_200)]
            engine.setPreviewSnapshot(snap, for: gpuBox.id)
            shot("expanded-apps", hovering: true, height: 640)
        }

        // 进度识别设置页 + 规则编辑
        var r1 = ProgressRule(); r1.name = "PyTorch"; r1.file = "*.log"; r1.pattern = "epoch"; r1.unit = "epoch"
        var r2 = ProgressRule(); r2.name = "MySolver"; r2.file = "out/*.txt"; r2.match = .regex; r2.pattern = "iter=("; r2.enabled = false
        store.settings.progressRules = [r1, r2]
        settingsShot("settings-rules", .rules, dark: true)
        let sheet = RuleEditorSheetPreview(rule: r1, hosts: store.settings.hosts, engine: engine)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        let hv = NSHostingView(rootView: sheet)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -5000, y: -5000))
        w.orderFrontRegardless()
        for _ in 0..<30 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) {
            hv.cacheDisplay(in: hv.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("settings-rule-editor.png"))
        }
        w.orderOut(nil)
        store.settings.progressRules = []
    }

    /// 规则编辑窗口的预览：带一个"测试成功"的结果。
    struct RuleEditorSheetPreview: View {
        var rule: ProgressRule
        var hosts: [HostConfig]
        var engine: MonitorEngine
        var body: some View {
            RuleEditorSheet(rule: rule, isNew: false, hosts: hosts, engine: engine, onSave: { _ in }, onDelete: {},
                            previewResult: RuleTestResult(ok: true, headline: L("当前值 37 · 目标值 100（37%）", "Current 37 · target 100 (37%)"),
                                                          notes: [L("文件：train.log", "File: train.log")]))
        }
    }

    /// 模拟桌面 + 菜单栏 + 硬件刘海。
    struct Desktop: View {
        var notchWidth: CGFloat
        var notchHeight: CGFloat

        var body: some View {
            ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.80, green: 0.62, blue: 0.62),
                                        Color(red: 0.95, green: 0.80, blue: 0.62)],
                               startPoint: .top, endPoint: .bottom)
                Rectangle().fill(.ultraThinMaterial).frame(height: notchHeight)
                    .overlay(alignment: .leading) {
                        HStack(spacing: 18) {
                            Image(systemName: "apple.logo")
                            Text("Finder").bold(); Text(L("文件", "File")); Text(L("编辑", "Edit")); Text(L("显示", "View"))
                        }
                        .font(.system(size: 13)).foregroundStyle(.white).padding(.leading, 16)
                    }
                UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9)
                    .fill(.black).frame(width: notchWidth, height: notchHeight)
            }
        }
    }
}

extension MonitorEngine {
    func setPreviewSnapshot(_ snap: HostSnapshot, for id: UUID) {
        setSnapshot(snap, for: id)
    }
}
