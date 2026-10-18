import Foundation

/// 自检：PBS（用本机 bash + awk 跑真正的转换脚本）、目录过滤、VASP 最大力曲线、日志清理。
enum SelfTestPBS {
    /// PBS Pro / OpenPBS 的 `qstat -f -t`：普通作业、被折行的 Variable_List、名字里有 |、数组（父作业 + 子作业）、hold。
    static let pbsProSample = """
    Job Id: 1001.pbs01
        Job_Name = relax_LLZO
        Job_Owner = demo@login01
        resources_used.walltime = 01:02:03
        job_state = R
        queue = workq
        exec_host = cn01/0*8+cn02/0*8
        Resource_List.nodect = 2
        Resource_List.walltime = 24:00:00
        stime = Fri Oct 17 09:00:00 2026
        Variable_List = PBS_O_HOME=/home/demo,PBS_O_LANG=en_US.UTF-8,PBS_O_WORKDI
    \tR=/home/demo/LLZO/relax,PBS_O_SYSTEM=Linux
        comment = Job run at Fri Oct 17 at 09:00 on (cn01:ncpus=8)+(cn02:ncpus=8)

    Job Id: 1002.pbs01
        Job_Name = md|300K
        job_state = Q
        queue = workq
        Resource_List.walltime = 48:00:00
        Variable_List = PBS_O_WORKDIR=/home/demo/other
        comment = Not Running: Insufficient amount of resource: ncpus

    Job Id: 1003[].pbs01
        Job_Name = scan
        job_state = B
        array_indices_submitted = 1-4

    Job Id: 1003[1].pbs01
        Job_Name = scan
        job_state = X
        Exit_status = 0

    Job Id: 1003[2].pbs01
        Job_Name = scan
        job_state = R
        resources_used.walltime = 00:10:00
        Resource_List.walltime = 01:00:00
        exec_host = cn03/0
        queue = workq
        Variable_List = PBS_O_WORKDIR=/home/demo/LLZO/scan

    Job Id: 1003[3].pbs01
        Job_Name = scan
        job_state = Q
        queue = workq
        Variable_List = PBS_O_WORKDIR=/home/demo/LLZO/scan

    Job Id: 1004.pbs01
        Job_Name = wait
        job_state = H
        queue = workq

    """

    /// Torque 和已结束的作业（qstat -x -f）：exit_status 小写、C 状态，PBS Pro 的 F 状态和信号 / 超时。
    static let endedSample = """
    Job Id: 2001.torque.example.org
        Job_Name = nep
        job_state = C
        exit_status = 0
        resources_used.walltime = 05:00:00
    Job Id: 2002.torque.example.org
        Job_Name = bad
        job_state = C
        exit_status = 1
        resources_used.walltime = 00:00:12
    Job Id: 2003.pbs01
        Job_Name = killed
        job_state = F
        Exit_status = 271
        stime = Fri Oct 17 09:00:00 2026
    Job Id: 2004.pbs01
        Job_Name = long
        job_state = F
        Exit_status = -29
        stime = Fri Oct 17 09:00:00 2026

    """

    static func run(_ check: (Bool, String) -> Void) {
        // —— PBS ——
        let q = bash(RemoteScript.pbsFunction + "si_pbs q <<'SI_EOF'\n" + pbsProSample + "SI_EOF\n")
        let qLines = q.components(separatedBy: "\n").filter { !$0.isEmpty }
        check(qLines.first == "1001|relax_LLZO|RUNNING|01:02:03|24:00:00|2|cn01,cn02|workq|1001|N/A",
              "PBS：运行中的作业转换成 squeue 格式（节点去重、续行拼接）")
        check(qLines.count == 5 && !q.contains("1003[]") && !q.contains("1003_1|"), "PBS：跳过数组父作业和已结束的子作业")
        let jobs = Parsers.groupArrays(Parsers.squeue(qLines))
        let pend = jobs.first { $0.id == "1002" }
        check(pend?.state == .pending && pend?.name == "md/300K" && pend?.reason == "Not Running: Insufficient amount of resource: ncpus",
              "PBS：排队作业的原因来自 comment，名称里的 | 不会打乱列")
        let arr = jobs.first { $0.id == "1003" }
        check(arr?.array?.running.count == 1 && arr?.array?.pending == 1 && arr?.array?.running.first?.id == "1003_2",
              "PBS：数组子作业 1003[2] 写成 1003_2 并合并成一行")
        check(jobs.first { $0.id == "1004" }?.reason?.hasPrefix("JobHeldUser") == true, "PBS：H 状态显示为被挂起")
        check(jobs.first { $0.id == "1001" }?.elapsed == 3723 && jobs.first { $0.id == "1001" }?.limit == 86400, "PBS：已运行和时间上限")

        let a = bash(RemoteScript.pbsFunction + "si_pbs a <<'SI_EOF'\n" + endedSample + "SI_EOF\n")
        let finals = Parsers.sacct(a.components(separatedBy: "\n"))
        check(finals["2001"]?.state == .completed && finals["2002"]?.state == .failed && finals["2003"]?.state == .cancelled
              && finals["2004"]?.state == .timeout && finals["2001"]?.elapsed == 18000,
              "PBS：结束状态（Torque 的 C / exit_status，PBS Pro 的 F，信号终止、超时）")

        let d = bash("printf '\(RemoteScript.marker)HOME /home/demo\\n'\n" + RemoteScript.pbsFunction + "si_pbs d <<'SI_EOF'\n" + pbsProSample + "SI_EOF\n")
        let wd = Parsers.workdirs(d.components(separatedBy: "\n"))
        check(wd.home == "/home/demo" && wd.dirs["1001"] == "/home/demo/LLZO/relax" && wd.dirs["1003_2"] == "/home/demo/LLZO/scan"
              && wd.dirs["1002"] == "/home/demo/other", "PBS：每个作业的工作目录（PBS_O_WORKDIR）")
        let w = bash(RemoteScript.pbsFunction + "si_pbs w <<'SI_EOF'\n" + pbsProSample + "SI_EOF\n")
        check(w.contains("1001|/home/demo/LLZO/relax") && !w.contains("1002|"), "PBS：计算软件识别只取运行中作业的目录")

        let kv = Parsers.pbsKeyValues(pbsProSample.components(separatedBy: "\n"))
        check(kv["Job_Name"] == "relax_LLZO" && kv["PBS_O_WORKDIR"] == "/home/demo/LLZO/relax" && kv["exec_host"] == "cn01/0*8+cn02/0*8",
              "PBS：详情页解析 qstat -f（含续行）")
        check(RemoteScript.pbsID("1003_2") == "1003[2]" && RemoteScript.pbsID("1001") == "1001", "PBS：作业号换回 PBS 的写法")

        var pbs = HostConfig(alias: "x", kind: .pbs); pbs.allowCancel = true; pbs.pathFilter = "~/LLZO"; pbs.slurmAlsoProcesses = true
        let pj = RemoteJob(id: "1003_2", name: "it's \"scan\"", state: .running, source: .slurm)
        let scripts = [RemoteScript.build(for: pbs), RemoteScript.detailScript(host: pbs, job: pj),
                       RemoteScript.cancelScript(host: pbs, job: pj, expectedElapsed: nil, force: false)!,
                       RemoteScript.sacctScript(for: pbs, jobIDs: ["1003_2", "1001"]), AppDetectors.script(host: pbs),
                       RemoteScript.build(for: { var h = HostConfig(alias: "x", kind: .slurm); h.pathFilter = "/data"; return h }())]
        check(scripts.allSatisfy(syntaxOK), "PBS：列表 / 详情 / 取消 / 结束状态 / 目录过滤脚本 bash 语法正确")
        check(scripts[2].contains("qdel '1003[2]'") && scripts[3].contains("qstat -x -f -t '1003[2]' '1001'"), "PBS：取消和结束状态用 PBS 的作业号")

        // —— 目录过滤 ——
        check(Parsers.pathMatches("/home/demo/LLZO/relax", prefixes: ["~/LLZO"], home: "/home/demo")
              && Parsers.pathMatches("/home/demo/LLZO", prefixes: ["/home/demo/LLZO/"], home: nil)
              && !Parsers.pathMatches("/home/demo/LLZO2/x", prefixes: ["/home/demo/LLZO"], home: nil)
              && !Parsers.pathMatches("/home/demo/other", prefixes: ["~/LLZO", "/scratch"], home: "/home/demo"),
              "目录过滤：子目录算在内，同名前缀（LLZO2）不算，~ 按远端家目录展开")
        var multi = HostConfig(alias: "x"); multi.pathFilter = "~/LLZO\n /scratch/demo ,\n\n"
        check(multi.pathPrefixes == ["~/LLZO", "/scratch/demo"], "目录过滤：每行一个（也认逗号），去掉空行")

        // —— VASP 最大力 ——
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-force-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func block(_ forces: [(Double, Double, Double)]) -> String {
            let dash = " " + String(repeating: "-", count: 83)
            return " POSITION                                       TOTAL-FORCE (eV/Angst)\n\(dash)\n"
                + forces.map { String(format: "      0.00000      0.00000      0.00000     %12.6f %12.6f %12.6f", $0.0, $0.1, $0.2) }.joined(separator: "\n")
                + "\n\(dash)\n    total drift:                                0.000000     0.000000     0.000000\n"
        }
        let outcar = dir.appendingPathComponent("OUTCAR")
        try? " vasp.6.4.2 18Apr23\n".appending(block([(0.3, 0.4, 0), (-0.1, 0, 0)])).appending(block([(0.03, 0, 0.04), (0, 0, 0.01)]))
            .appending(" POSITION                                       TOTAL-FORCE (eV/Angst)\n " + String(repeating: "-", count: 83) + "\n      0.0 0.0 0.0  0.2 0.0 0.0\n")
            .write(to: outcar, atomically: true, encoding: .utf8)
        try? "SYSTEM = test\n  EDIFFG = -0.02   ! force\nIBRION = 2\n".write(to: dir.appendingPathComponent("INCAR"), atomically: true, encoding: .utf8)
        let src = AppCurves.Source.vaspForce(path: outcar.path)
        let c1 = AppCurves.merge(bash(AppCurves.script(src, offset: 0, head: "")), into: CurveCache())
        let curve1 = c1.flatMap { AppCurves.curve(src, rows: $0.rows, extra: $0.extra) }
        check(c1?.rows.count == 2 && abs((c1?.rows.first?[1] ?? 0) - 0.5) < 1e-6 && abs((c1?.rows.last?[1] ?? 0) - 0.05) < 1e-6,
              "VASP：每个离子步的最大力 |F|（OUTCAR 的 TOTAL-FORCE 块）")
        check(curve1?.threshold == 0.02 && curve1?.logY == true && curve1?.series.first?.points.last?.x == 2, "VASP：EDIFFG < 0 时画出收敛目标")
        // 写到一半的第三个块不算；补全后增量读取接着算
        if let h = try? FileHandle(forWritingTo: outcar) {
            h.seekToEndOfFile()
            h.write(Data((" " + String(repeating: "-", count: 83) + "\n").utf8))
            try? h.close()
        }
        let c2 = c1.flatMap { AppCurves.merge(bash(AppCurves.script(src, offset: $0.lineCount, head: $0.head)), into: $0) }
        check(c2?.rows.count == 3 && abs((c2?.rows.last?[1] ?? 0) - 0.2) < 1e-6, "VASP：增量读取时不丢写到一半的力块")
        check(AppCurves.sources(for: { var a = AppProgress(kind: .vasp, dir: "/d"); a.vaspMode = .relax; return a }()).count == 2,
              "VASP：结构优化有能量和最大力两张图")

        // —— 检查更新 ——
        check(UpdateChecker.compare("0.10.0", "0.9.1") == 1 && UpdateChecker.compare("0.2", "0.2.0") == 0
              && UpdateChecker.compare("0.2.0", "0.2.1") == -1 && UpdateChecker.compare("1.0.0-beta", "1.0.0") == 0,
              "更新：版本号按数字逐段比较")
        let rel = ###"{"tag_name":"v0.3.0","html_url":"https://github.com/zhyan0603/ServerIsland/releases/tag/v0.3.0","body":"## What's new\r\n\r\n- PBS\r\n- Folder filter","assets":[{"name":"ServerIsland-0.3.0-win-x64.zip","browser_download_url":"https://example.org/w.zip"},{"name":"ServerIsland-0.3.0.dmg","browser_download_url":"https://example.org/m.dmg"}]}"###
        let parsed = UpdateChecker.parse(Data(rel.utf8), assetSuffix: ".dmg")
        check(parsed?.version == "0.3.0" && parsed?.downloadURL.absoluteString == "https://example.org/m.dmg" && parsed?.notes == "- PBS\n- Folder filter",
              "更新：解析 GitHub Release（去掉 v、选对安装包、说明跳过标题）")
        check(UpdateChecker.parse(Data(#"{"tag_name":"v1","html_url":"https://x.org/r","assets":[]}"#.utf8), assetSuffix: ".dmg")?.downloadURL.absoluteString == "https://x.org/r",
              "更新：没有对应安装包时打开 Release 页面")
        check(UpdateChecker.summary("<p align=\"center\">\n<img src=\"x\">\n</p>\n<h1>v1</h1>\nIntro line\n- **A**: one\n- B") == "- **A**: one\n- B",
              "更新：说明摘要跳过 HTML，优先取列表项")

        // —— 日志清理 ——
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        let now = f.date(from: "2026-10-17 12:00:00")!
        let text = "2026-10-01 10:00:00  old\n  continuation of old\n10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n"
        let kept = DebugLog.pruneText(text, cutoff: now.addingTimeInterval(-3 * 86400), now: now)
        check(kept == "10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n",
              "日志：删除早于保留天数的行（续行跟随上一行，旧格式按今年算）")
        check(DebugLog.pruneText("2026-01-01 00:00:00  x\n", cutoff: now, now: now).isEmpty, "日志：全部过期时清空")
    }

    static func bash(_ script: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inPipe.fileHandleForWriting.close()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    static func syntaxOK(_ script: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-n"]
        let inPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        inPipe.fileHandleForWriting.write(Data(script.utf8))
        try? inPipe.fileHandleForWriting.close()
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}
