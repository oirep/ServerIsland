import Foundation

/// 计算软件识别的自检：在本机临时目录里造假的 VASP / LAMMPS / 自定义输出，
/// 用本机 bash 真正执行生成的远端脚本，再解析结果。
/// （macOS 自带的是 BSD awk / grep，顺便检查脚本没有用到 GNU 专有写法。）
enum SelfTestApps {
    static func run(_ check: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        func make(_ dir: String, _ files: [String: String]) -> String {
            let d = root.appendingPathComponent(dir)
            try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            for (name, text) in files {
                let url = d.appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? text.write(to: url, atomically: true, encoding: .utf8)
            }
            return d.path
        }

        func detect(_ dir: String, rules: [ProgressRule] = [], builtin: Bool = true) -> AppProgress? {
            let lines = bash(AppDetectors.directoryScript(id: "t", dir: dir, rules: rules, builtin: builtin)).components(separatedBy: "\n")
            return AppDetectors.parse(lines, rules: rules)["t"]
        }

        func bash(_ script: String) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-s"]
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return "" }
            input.fileHandleForWriting.write(script.data(using: .utf8)!)
            try? input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }

        // MARK: VASP

        let oszMD = """
               N       E                     dE             d eps       ncg     rms          rms(c)
        DAV:   1     0.123E+03    0.123E+03   -0.5E+03  1000   0.1E+02
        RMM:   2    -0.101E+03   -0.22E+03   -0.3E+02  1200   0.4E+01
           1 T=   300. E= -.10E+03 F= -.11E+03 E0= -.11E+03  EK= 0.1E+01 SP= 0.0E+00 SK= 0.0E+00
        DAV:   1    -0.111E+03   -0.1E-01   -0.3E-01  1000   0.2E+00
           2 T=   310. E= -.10E+03 F= -.11E+03 E0= -.11E+03  EK= 0.1E+01 SP= 0.0E+00 SK= 0.0E+00
        RMM:   3    -0.111E+03   -0.1E-03   -0.1E-03  1000   0.1E-01

        """
        let md = detect(make("vasp-md", ["INCAR": "SYSTEM = test\nIBRION = 0 ; NSW = 500   ! MD\nPOTIM = 1\n",
                                         "OSZICAR": oszMD, "OUTCAR": " running on 4 nodes\n"]))
        check(md?.vaspMode == .md && md?.current == 2 && md?.total == 500 && md?.endMarker == false, "VASP MD：离子步 / NSW")

        let oszRelax = """
        DAV:   1     0.4E+03    0.4E+03   -0.1E+04  1000   0.1E+02
           1 F= -.43E+03 E0= -.43E+03  d E =-.43E+03  mag=     2.0
        RMM:   5    -0.43E+03   -0.1E-04   -0.1E-04  1000   0.1E-01
           2 F= -.44E+03 E0= -.44E+03  d E =-.1E+01  mag=     2.0
           3 F= -.44E+03 E0= -.44E+03  d E =-.1E-02  mag=     2.0

        """
        let relax = detect(make("vasp-relax", ["INCAR": "ibrion=2; nsw=200\nEDIFFG = -0.01 # force\n", "OSZICAR": oszRelax,
                                               "OUTCAR": "...\n General timing and accounting informations for this job:\n Total CPU time used (sec): 1.0\n"]))
        check(relax?.vaspMode == .relax && relax?.current == 3 && relax?.total == nil && relax?.fraction == nil
              && relax?.endMarker == true && relax?.finished == true, "VASP 结构优化：只显示离子步（小写、分号、注释）")

        let scf = detect(make("vasp-scf", ["INCAR": "ENCUT = 500\n", "OSZICAR": "DAV:   1  0.1E+03\nDAV:  11  0.1E+03\nRMM:  12  0.1E+03\n"]))
        check(scf?.vaspMode == .scf && scf?.current == 12 && scf?.endMarker == nil, "VASP 单点：电子步")

        let phonon = detect(make("vasp-phonon", ["INCAR": "IBRION = 6\nNSW = 1\n", "OSZICAR": oszRelax]))
        check(phonon == nil, "VASP 声子（IBRION=6）不识别")
        let mdOver = detect(make("vasp-md-bad", ["INCAR": "IBRION = 0\nNSW = 1\n", "OSZICAR": oszMD]))
        check(mdOver == nil, "VASP MD 离子步超过 NSW 时不显示")

        // MARK: LAMMPS

        let lmpHead = """
        LAMMPS (2 Aug 2023)
        units metal
        thermo 100
        run 500
           Step          Temp          E_pair
                 0   300           -3.5
               500   290           -3.5
        Loop time of 1.0 on 4 procs for 500 steps with 1000 atoms

        fix 2 all npt temp 300 300 0.1 iso 0 0 1
        run 1000
        Neighbor list info ...
          update: every = 1 steps, delay = 0 steps, check = yes
        Per MPI rank memory allocation (min/avg/max) = 3.1 | 3.1 | 3.1 Mbytes
           Step          Temp          E_pair         TotEng         Press
               500   300           -3.5            -3.4            100
               600   301.2         -3.5            -3.4            -20.5
        WARNING: Something happened (src/foo.cpp:12)
               700   299.1         -3.5            -3.4            1.5e+02

        """
        let lmp = detect(make("lmp-run", ["log.lammps": lmpHead]))
        check(lmp?.kind == .lammps && lmp?.current == 200 && lmp?.total == 1000 && lmp?.endMarker == false, "LAMMPS：最后一段 run 的进度")

        let lmpDone = lmpHead + """
               1500   300           -3.5            -3.4            12
        Loop time of 12.3 on 4 procs for 1000 steps with 1000 atoms
        Nlocal:           1000 ave        1000 max        1000 min
        Total # of neighbors = 64000
        Total wall time: 0:00:13

        """
        let done = detect(make("lmp-done", ["log.lammps": lmpDone]))
        check(done?.current == 1000 && done?.endMarker == true && done?.finished == true, "LAMMPS：Total wall time 判定正常结束")

        let lmpMin = lmpDone.replacingOccurrences(of: "Total wall time: 0:00:13\n", with: "minimize 1e-6 1e-8 1000 10000\n   Step  Temp  E_pair\n  1500 0 -3.6\n")
        check(detect(make("lmp-min", ["log.lammps": lmpMin])) == nil, "LAMMPS：run 之后接 minimize 时不显示")
        let lmpVar = "LAMMPS\nvariable n equal 1000\nrun ${n}\n   Step Temp\n  0 300\n  100 300\n"
        check(detect(make("lmp-var", ["log.lammps": lmpVar])) == nil, "LAMMPS：run 步数是变量且没有展开时不显示")
        let lmpMulti = "LAMMPS\nthermo_style multi\nrun 1000\n------------ Step              0 ----- CPU =      0.0 (sec) ----\nTotEng   =     -3.4 KinEng   =      0.1\n"
        check(detect(make("lmp-multi", ["log.lammps": lmpMulti])) == nil, "LAMMPS：thermo_style multi 不显示")

        // MARK: 自定义规则

        var kw = ProgressRule()
        kw.name = "PyTorch"; kw.file = "*.log"; kw.pattern = "epoch"; kw.unit = "epoch"; kw.doneMarker = "Training finished"
        let kwDir = make("custom-kw", ["train.log": "Epoch 36/100 loss 0.5\nEpoch 37/100 loss 0.4\nvalidating...\n"])
        let k = detect(kwDir, rules: [kw])
        check(k?.kind == .custom && k?.title == "PyTorch" && k?.current == 37 && k?.total == 100 && k?.endMarker == false,
              "自定义规则：关键字 + 自动识别 a/b")
        check(detect(kwDir, rules: [kw], builtin: false)?.current == 37, "自定义规则：只测试这一条（不跑内置识别）")

        let okTest = AppDetectors.interpretTest(bash(AppDetectors.ruleTestScript(dir: kwDir, rule: kw)), rule: kw)
        check(okTest.ok && okTest.headline.contains("37") && okTest.headline.contains("100"), "测试规则：匹配成功")
        var kwBad = kw; kwBad.pattern = "loss_total"
        let badTest = AppDetectors.interpretTest(bash(AppDetectors.ruleTestScript(dir: kwDir, rule: kwBad)), rule: kwBad)
        check(!badTest.ok && badTest.lines.contains("validating..."), "测试规则：没匹配上时给出文件最后几行")
        var kwNoFile = kw; kwNoFile.file = "*.csv"
        check(AppDetectors.interpretTest(bash(AppDetectors.ruleTestScript(dir: kwDir, rule: kwNoFile)), rule: kwNoFile).headline.contains("*.csv"),
              "测试规则：文件不存在")
        check(AppDetectors.interpretTest(bash(AppDetectors.ruleTestScript(dir: kwDir + "/nope", rule: kw)), rule: kw).headline.contains("目录"),
              "测试规则：目录不存在")

        var re = ProgressRule()
        re.name = "MySim"; re.file = "progress.txt"; re.match = .regex; re.pattern = #"iter=(\d+).*target=(\d+)"#
        let r = detect(make("custom-re", ["progress.txt": "start\niter=1234 of target=5000\n"]), rules: [re])
        check(r?.current == 1234 && r?.total == 5000, "自定义规则：正则捕获组")

        var tf = ProgressRule()
        tf.name = "Solver"; tf.file = "run.log"; tf.pattern = "step"; tf.totalFile = "config.ini"; tf.totalKeyword = "max_steps"
        let t = detect(make("custom-tf", ["run.log": "step 100\nstep 120 residual 1e-3\n", "config.ini": "[run]\nmax_steps = 1000\n"]), rules: [tf])
        check(t?.current == 120 && t?.total == 1000 && t?.endMarker == nil, "自定义规则：从另一个文件读目标值")

        let over = detect(make("custom-over", ["train.log": "Epoch 120/100\n"]), rules: [kw])
        check(over == nil, "自定义规则：当前值超过目标值时不显示")

        // 自定义规则排在内置识别前面：同一个目录里既有 log.lammps 也匹配规则时，用规则
        var lr = ProgressRule()
        lr.name = "My LAMMPS"; lr.file = "log.lammps"; lr.pattern = "run"
        check(detect(make("lmp-rule", ["log.lammps": lmpHead]), rules: [lr])?.kind == .custom, "自定义规则优先于内置识别")

        // MARK: 详情页曲线（增量读取）

        let lossDir = make("curve-nep", ["loss.out": """
        100 0.30 0.01 0.02 0.20 0.50 0.10 0 0 0
        200 0.20 0.01 0.02 0.10 0.40 0.08 0 0 0
        300 0.15 0.01 0.02 0.08 0.30 0.06 0 0 0

        """])
        let lossFile = lossDir + "/loss.out"
        let lossSrc = AppCurves.Source.loss(path: lossFile, gnep: false)
        var cache = AppCurves.merge(bash(AppCurves.script(lossSrc, offset: 0, head: "")), into: CurveCache())
        check(cache?.rows.count == 3 && cache?.lineCount == 3, "曲线：第一次读取全部行")
        // 追加两行完整的 + 半行（还没写完）
        if let h = FileHandle(forWritingAtPath: lossFile) {
            h.seekToEndOfFile()
            h.write("400 0.12 0.01 0.02 0.07 0.25 0.05 0 0 0\n500 0.10 0.01 0.02 0.06 0.20 0.04 0 0 0\n600 0.0".data(using: .utf8)!)
            try? h.close()
        }
        let incOut = bash(AppCurves.script(lossSrc, offset: cache?.lineCount ?? 0, head: cache?.head ?? ""))
        cache = cache.flatMap { AppCurves.merge(incOut, into: $0) }
        check(!incOut.contains("reset=1") && incOut.components(separatedBy: "row=").count - 1 == 2 && cache?.rows.count == 5
              && cache?.rows.last?.first == 500, "曲线：增量只读新增的完整行（半行不读）")
        let c = cache.flatMap { AppCurves.curve(lossSrc, rows: $0.rows) }
        check(c?.logY == true && c?.series.map(\.name) == ["Total", "能量", "力", "维里"] && c?.series.first?.points.count == 5,
              "曲线：NEP loss 各列")
        // 重新训练：文件被重写，第一行变了
        try? "100 0.90 0.01 0.02 0.20 0.50 0.10 0 0 0\n200 0.80 0.01 0.02 0.10 0.40 0.08 0 0 0\n".write(toFile: lossFile, atomically: true, encoding: .utf8)
        cache = cache.flatMap { AppCurves.merge(bash(AppCurves.script(lossSrc, offset: $0.lineCount, head: $0.head)), into: $0) }
        check(cache?.rows.count == 2 && cache?.rows.first?[1] == 0.9, "曲线：文件重写后从头读")

        let oszDir = make("curve-vasp", ["OSZICAR": oszRelax])
        let vSrc = AppCurves.Source.vaspEnergy(path: oszDir + "/OSZICAR")
        let vCache = AppCurves.merge(bash(AppCurves.script(vSrc, offset: 0, head: "")), into: CurveCache())
        let vc = vCache.flatMap { AppCurves.curve(vSrc, rows: $0.rows) }
        check(vCache?.rows.count == 3 && vCache?.rows.last == [3, -440] && vc?.logY == false, "曲线：VASP 离子步 E0")
        check(AppCurves.merge(bash(AppCurves.script(.loss(path: lossDir + "/nope", gnep: false), offset: 0, head: "")), into: CurveCache()) == nil,
              "曲线：文件不存在")

        // 完整的轮询脚本（含两条规则）语法正确
        let saved = ProgressRule.active
        ProgressRule.active = [kw, tf]
        var syntaxOK = true
        for kind in [HostKind.slurm, .direct] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = ["-n"]
            let input = Pipe()
            p.standardInput = input
            p.standardError = FileHandle.nullDevice
            if (try? p.run()) == nil { syntaxOK = false; continue }
            input.fileHandleForWriting.write(AppDetectors.script(host: HostConfig(alias: "x", kind: kind)).data(using: .utf8)!)
            try? input.fileHandleForWriting.close()
            p.waitUntilExit()
            if p.terminationStatus != 0 { syntaxOK = false }
        }
        ProgressRule.active = saved
        check(syntaxOK, "轮询脚本（含自定义规则）bash 语法检查")

        check(ProgressRule.isSafeFileName("logs/*.log") && !ProgressRule.isSafeFileName("a;rm -rf ~")
              && !ProgressRule.isSafeFileName("../x") && !ProgressRule.isSafeFileName("$(id)"), "规则文件名只允许安全字符")

        // 文件没变时跳过重读：si_same 只在目录和签名都对上时成立；same=1 解析成"沿用上次"，sig= 记成签名
        let same = AppDetectors.sameFunction(["/w/it's a|b": "1.2 3.4 ", "/w/x": "9.9 "]) + """

        si_same "/w/it's a|b" "1.2 3.4 " && echo hit1; si_same "/w/it's a|b" "1.2 3.5 " || echo miss1
        si_same "/w/y" "9.9 " || echo miss2; si_same "/w/x" "" || echo miss3

        """
        check(bash(same).split(separator: "\n") == ["hit1", "miss1", "miss2", "miss3"], "跳过重读：签名比较（目录带引号和 |）")
        let skip = AppDetectors.parse(["@@SI:DIR 7|/w/a", "kind=vasp", "same=1", "@@SI:DIR 8|/w/b", "kind=lammps", "sig=5.6 ",
                                       "total=100", "first=0", "last=50", "bad=0", "@@SI:DIR 9|/w/c", "kind=lammps", "sig=",
                                       "total=100", "first=0", "last=50", "bad=0"])
        check(skip["7"]?.unchanged == true && skip["7"]?.dir == "/w/a" && skip["8"]?.signature == "5.6 " && skip["8"]?.current == 50
              && skip["9"]?.signature == nil, "跳过重读：解析 same=1 和签名")
    }
}
