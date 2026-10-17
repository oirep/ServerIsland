import Foundation

/// `ServerIsland --selftest`：用样例输出检查解析逻辑。
enum SelfTest {
    static func run() -> Bool {
        Lang.setting = .zh
        var ok = true
        func check(_ cond: Bool, _ name: String) {
            print((cond ? "✓ " : "✗ ") + name)
            if !cond { ok = false }
        }

        check(Parsers.slurmDuration("1-02:03:04") == 93784, "slurm 时长 d-hh:mm:ss")
        check(Parsers.slurmDuration("45:16") == 2716, "slurm 时长 mm:ss")
        check(Parsers.slurmDuration("4:00:00") == 14400, "slurm 时长 h:mm:ss")
        check(Parsers.slurmDuration("UNLIMITED") == nil, "slurm 时长 UNLIMITED")
        check(Parsers.slurmDuration("2-00") == 172800, "slurm 时长 d-hh")

        let output = """
        Welcome to cluster!
        @@SI:BEGIN
        @@SI:SEC cpu
        cpu  100 0 50 800 50 0 0 0 0 0
        64
        6.20 5.80 5.10 3/1200 4242
        @@SI:RC 0
        @@SI:SEC mem
        MemTotal:       263842716 kB
        MemAvailable:   160000000 kB
        @@SI:RC 0
        @@SI:SEC gpu
        0, NVIDIA A100-SXM4-80GB, 97, 61000, 81920, 66
        1, NVIDIA A100-SXM4-80GB, 0, 3, 81920, 31
        @@SI:RC 0
        @@SI:SEC squeue
        4821337|pretrain_7b|RUNNING|4:24:00|2-00:00:00|2|gpu[03-04]|a100
        4821455|eval_mmlu|PENDING|0:00|2:00:00|1|(Priority)|a100
        @@SI:RC 0
        @@SI:SEC progress
        @@SI:FILE /home/u/.serverisland/progress/pretrain.json
        {"name":"pretrain_7b","progress":0.62,"message":"step 12400/20000","jobid":"4821337"}
        @@SI:FILE /home/u/.serverisland/progress/bad.json
        not json
        @@SI:RC 0
        @@SI:END
        """
        let parsed = RemoteScript.parse(output)
        check(parsed.sawBegin && parsed.sawEnd, "识别 BEGIN/END，忽略登录横幅")
        let cpu = Parsers.cpu(parsed.sections["cpu"]?.lines ?? [])
        check(cpu.cores == 64 && cpu.load1 == 6.2 && cpu.sample?.total == 1000, "CPU 解析")
        let mem = Parsers.memory(parsed.sections["mem"]?.lines ?? [])
        check(mem != nil && abs(mem!.total - 263842716 * 1024) < 1, "内存解析")
        let gpus = Parsers.gpus(parsed.sections["gpu"]?.lines ?? [])
        check(gpus.count == 2 && gpus[0].utilization == 97 && gpus[1].memoryTotalMB == 81920, "GPU 解析")
        let jobs = Parsers.squeue(parsed.sections["squeue"]?.lines ?? [])
        check(jobs.count == 2 && jobs[0].state == .running && jobs[0].limit == 172800 && jobs[1].state == .pending,
              "squeue 解析")
        let prog = Parsers.progress(parsed.sections["progress"]?.lines ?? [])
        check(prog.count == 1 && prog[0].jobID == "4821337" && prog[0].progress == 0.62, "进度文件解析（跳过坏文件）")

        let procs = Parsers.processes([
            "  18342  9250 312.0 8123456 /usr/bin/python3 -u train_diffusion.py --lr 3e-4",
            "  20977   400   0.1   20480 -bash",
            "  20999    10   0.0    1024 ps -u yan -o pid=",
        ], filter: "python|torchrun", gpuMem: ["18342": 61000])
        check(procs.count == 1 && procs[0].name == "python3 train_diffusion.py" && procs[0].gpuMemoryMB == 61000,
              "直连进程过滤")

        let sacct = Parsers.sacct(["4821337|pretrain_7b|COMPLETED|11:42:05|0:0", "4821455|eval_mmlu|OUT_OF_MEMORY|00:42:18|0:125"])
        check(sacct["4821337"]?.state == .completed && sacct["4821455"]?.state == .failed, "sacct 最终状态")

        let script = RemoteScript.build(for: HostConfig(alias: "x", kind: .slurm))
        check(script.contains("squeue") && script.contains("@@SI:END"), "生成远端脚本")

        // 在本机 bash 上真实执行一遍直连脚本：macOS 没有 /proc，应当优雅地产生 warning 而不是中断。
        var direct = HostConfig(alias: "local", kind: .direct)
        direct.showGPU = true
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-s"]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = outPipe
        try? p.run()
        try? inPipe.fileHandleForWriting.write(contentsOf: Data(RemoteScript.build(for: direct).utf8))
        try? inPipe.fileHandleForWriting.close()
        let out = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        let localParsed = RemoteScript.parse(out)
        check(localParsed.sawBegin && localParsed.sawEnd && localParsed.sections["procs"] != nil,
              "脚本可在 bash 中完整执行（各段：\(localParsed.sections.keys.sorted().joined(separator: ",")))")

        let df = Parsers.disks(["Filesystem 1024-blocks Used Available Capacity Mounted on",
                                "/dev/nvme0n1p2 960000000 912000000 48000000 95% /",
                                "nas:/home 2000000000 1000000000 1000000000 50% /mnt/my home"])
        check(df.count == 2 && abs(df[0].fraction - 0.95) < 0.001 && df[1].mount == "/mnt/my home", "df 解析（含空格挂载点）")

        let kv = Parsers.keyValues("JobId=4821337 JobName=pretrain 7b UserId=yan(1000) JobState=RUNNING Reason=None StdOut=/home/yan/logs/out-4821337.log WorkDir=/home/yan/proj")
        check(kv["JobName"] == "pretrain 7b" && kv["StdOut"] == "/home/yan/logs/out-4821337.log" && kv["JobState"] == "RUNNING",
              "scontrol key=value 解析")

        let hist = Parsers.history(["4821001|pretrain|COMPLETED|11:42:05|2026-10-16T09:12:00|0:0",
                                    "4821002|eval|FAILED|00:02:10|2026-10-16T10:00:00|1:0",
                                    "4821003|run|RUNNING|00:10:00|Unknown|0:0"])
        check(hist.count == 2 && hist[0].id == "4821002" && hist[0].jobState == .failed, "sacct 历史解析（跳过运行中）")

        // 生成的详情 / 取消 / 历史脚本在 bash 下语法正确（只做 -n 语法检查，不执行）。
        var slurm = HostConfig(alias: "x", kind: .slurm); slurm.allowCancel = true
        let sj = RemoteJob(id: "4821337", name: "it's \"quoted\"", state: .running, source: .slurm)
        let pj = RemoteJob(id: "18342", name: "python3 train.py", state: .running, source: .process)
        let scripts = [
            RemoteScript.detailScript(host: slurm, job: sj),
            RemoteScript.detailScript(host: HostConfig(alias: "x"), job: pj),
            RemoteScript.cancelScript(host: slurm, job: sj, expectedElapsed: nil, force: false)!,
            RemoteScript.cancelScript(host: HostConfig(alias: "x"), job: pj, expectedElapsed: 9250, force: false)!,
            RemoteScript.cancelScript(host: HostConfig(alias: "x"), job: pj, expectedElapsed: 9250, force: true)!,
            RemoteScript.historyScript(host: slurm),
            RemoteScript.topProcessesScript(host: HostConfig(alias: "x")),
            AppDetectors.finalStateScript(id: "123", dir: "/home/u/it's dir"),
            RemoteScript.build(for: { var h = HostConfig(alias: "x"); h.watched = [WatchedProcess(pid: "1", name: "")]; return h }()),
        ]
        for (i, sc) in scripts.enumerated() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n"]
            let inPipe = Pipe(), errPipe = Pipe()
            p.standardInput = inPipe; p.standardError = errPipe
            try? p.run()
            try? inPipe.fileHandleForWriting.write(contentsOf: Data(sc.utf8))
            try? inPipe.fileHandleForWriting.close()
            p.waitUntilExit()
            let err = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            check(p.terminationStatus == 0, "脚本 \(i) bash 语法" + (err.isEmpty ? "" : "：" + err))
        }
        // Job Array
        let arr = Parsers.squeue([
            "123_5|sweep|lr|RUNNING|1:00|4:00:00|1|gpu01|a100|123|5",
            "123_6|sweep|lr|RUNNING|0:30|4:00:00|1|gpu02|a100|123|6",
            "123_[7-99%10]|sweep|lr|PENDING|0:00|4:00:00|1|(JobArrayTaskLimit)|a100|123|[7-99%10]",
            "200|single|RUNNING|0:10|1:00:00|1|gpu03|a100|200|N/A",
            "300_[1-4]|old|PENDING|0:00|1:00:00|1|(Priority)|a100",
        ])
        check(arr.count == 5 && arr[0].name == "sweep|lr" && arr[0].arrayJobID == "123" && arr[2].arrayTask == "[7-99%10]"
              && arr[3].arrayJobID == nil && arr[4].arrayJobID == "300", "squeue 数组解析（含名称里的 |、老格式）")
        check(Parsers.arrayTaskCount("[7-99%10]") == 93 && Parsers.arrayTaskCount("[1,3,5-7]") == 5
              && Parsers.arrayTaskCount("[1-99:2]") == 50, "数组范围计数")
        let grouped = Parsers.groupArrays(arr)
        let g = grouped.first { $0.id == "123" }
        check(grouped.count == 3 && g?.array?.running.count == 2 && g?.array?.pending == 93 && g?.state == .running
              && grouped.reduce(0, { $0 + $1.runningUnits }) == 3 && grouped.reduce(0, { $0 + $1.pendingUnits }) == 97,
              "数组合并为一行，按元素计数")
        let ah = Parsers.history(["123_1|sweep|COMPLETED|0:10:00|2026-10-16T09:00:00|0:0",
                                  "123_2|sweep|FAILED|0:01:00|2026-10-16T09:05:00|1:0",
                                  "123_3|sweep|COMPLETED|0:09:00|2026-10-16T09:06:00|0:0"])
        check(ah.count == 1 && ah[0].note == "数组 2✓ 1✗", "历史里的数组元素合并")
        check(RemoteScript.safeSlurmID("123_5") == "123_5" && RemoteScript.safeSlurmID("123;rm") == nil, "作业号校验")

        // 计算软件识别
        let appsOut = AppDetectors.parse([
            "@@SI:DIR 1275823|/home/u/nep/train",
            "kind=nep", "total=100000", "last=   12000 0.12345 0.01 0.002 0.003 0.08 0.01", "mtime=1760600000",
            "@@SI:DIR 4821337_5|/scratch/u/md/300K",
            "kind=gpumd", "total=2000000", "interval=1000",
            "neighbor=Neighbor info at step 1200000: radial(max=120,actual=48), angular(max=60,actual=21).", "mtime=1760600000",
            "@@SI:DIR 99|/scratch/u/md2", "kind=gpumd", "interval=100", "thermo_rows=500", "mtime=1",
        ])
        check(appsOut["1275823"]?.current == 12000 && appsOut["1275823"]?.fraction == 0.12
              && appsOut["1275823"]?.losses.first?.label == "Total" && appsOut["1275823"]?.losses.count == 6, "NEP loss.out / nep.in 解析")
        check(appsOut["4821337_5"]?.current == 1_200_000 && appsOut["4821337_5"]?.fraction == 0.6
              && appsOut["4821337_5"]?.neighbor?.radialActual == 48, "GPUMD neighbor.out / run.in 解析")
        check(appsOut["99"]?.current == 50_000 && appsOut["99"]?.hasTarget == false, "GPUMD thermo.out 退化路径（无 run 步数）")
        check(PendingReason.explain("DependencyNeverSatisfied")?.needsAction == true
              && PendingReason.explain("Dependency")?.short == "等待依赖作业"
              && PendingReason.explain("AssocGrpBillingRunMinutes")?.short == "组计费额度已满"
              && PendingReason.explain("Job's QOS not permitted to use this partition (CPU-MISC allows rush-cpu)")?.needsAction == true,
              "排队原因翻译")

        let cancelS = RemoteScript.cancelScript(host: slurm, job: sj, expectedElapsed: nil, force: false)!
        check(cancelS.contains("squeue -h -j 4821337") && cancelS.contains("scancel 4821337"), "取消前先核对作业")
        SelfTestApps.run(check)
        return ok
    }

    @MainActor
    static func diagnose(alias: String, kind: HostKind, alsoProcesses: Bool = false) async {
        let store = ConfigStore(persist: false)
        var host = HostConfig(alias: alias, kind: kind)
        host.slurmAlsoProcesses = alsoProcesses
        store.settings.hosts = [host]
        let engine = MonitorEngine(store: store)
        print(await engine.diagnose(host))
        print("\n===== 解析结果 =====")
        await engine.pollForDiagnosis(host)
        guard let snap = engine.snapshots[host.id] else { return }
        print("health:", snap.health)
        print("metrics:", snap.metrics)
        for g in snap.gpus { print("gpu:", g) }
        for j in snap.jobs {
            print("job:", j.id, j.name, j.state, j.elapsed ?? -1, j.detail.prefix(80))
            if let m = j.message { print("     message:", m, "progress:", j.progress.map { Format.percent($0) } ?? "-") }
            if let a = j.app { print("     losses:", a.losses.map { "\($0.label)=\($0.value)" }.joined(separator: " ")) }
        }
        print("warnings:", snap.warnings)
        for d in snap.disks { print("disk:", d.mount, Format.percent(d.fraction)) }
        print("\n===== 高负载进程（监听候选） =====")
        let top = await engine.topProcesses(host: host) ?? []
        for p in top { print(p.id, p.name, p.cpuPercent ?? 0, p.gpuMemoryMB ?? 0) }
        if let first = top.first {
            print("\n===== 详情：pid \(first.id) =====")
            let d = await engine.fetchDetail(host: host, job: first)
            for (k, v) in d.fields { print(k, "=", v) }
            print("stdout:", d.stdout.path ?? "-", d.stdout.note ?? "", "lines:", d.stdout.lines.count)
            d.stdout.lines.suffix(5).forEach { print("  |", $0) }
            if let e = d.stderr { print("stderr:", e.path ?? "-", e.note ?? "") }
            print("error:", d.error ?? "-")
        }
        let h = await engine.fetchHistory(host: host)
        print("\nhistory: fromServer=\(h.fromServer) count=\(h.entries.count)")
    }
}
