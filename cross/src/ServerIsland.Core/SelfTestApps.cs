namespace ServerIsland.Core;

/// 计算软件识别的自检：在本机临时目录里造假的 VASP / LAMMPS / 自定义输出，
/// 用本机 bash 真正执行生成的远端脚本，再解析结果。（与 Swift 版 SelfTestApps.swift 一一对应）
public static class SelfTestApps
{
    public static void Run(Action<bool, string> check)
    {
        var root = Path.Combine(Path.GetTempPath(), "si-selftest-" + Guid.NewGuid().ToString("N"));
        try { RunIn(root, check); }
        finally { try { Directory.Delete(root, true); } catch { } }
    }

    static void RunIn(string root, Action<bool, string> check)
    {
        string Make(string dir, Dictionary<string, string> files)
        {
            var d = Path.Combine(root, dir);
            Directory.CreateDirectory(d);
            foreach (var (name, text) in files)
            {
                var f = Path.Combine(d, name);
                Directory.CreateDirectory(Path.GetDirectoryName(f)!);
                File.WriteAllText(f, text);
            }
            return d.Replace('\\', '/');
        }

        string Bash(string script) => SelfTest.Bash(script, "-s");

        AppProgress? Detect(string dir, List<ProgressRule>? rules = null, bool builtin = true)
        {
            rules ??= [];
            var lines = Bash(AppDetectors.DirectoryScript("t", dir, rules, builtin)).Split('\n');
            return AppDetectors.Parse(lines, rules).GetValueOrDefault("t");
        }

        // MARK: VASP

        var oszMD = """
               N       E                     dE             d eps       ncg     rms          rms(c)
            DAV:   1     0.123E+03    0.123E+03   -0.5E+03  1000   0.1E+02
            RMM:   2    -0.101E+03   -0.22E+03   -0.3E+02  1200   0.4E+01
               1 T=   300. E= -.10E+03 F= -.11E+03 E0= -.11E+03  EK= 0.1E+01 SP= 0.0E+00 SK= 0.0E+00
            DAV:   1    -0.111E+03   -0.1E-01   -0.3E-01  1000   0.2E+00
               2 T=   310. E= -.10E+03 F= -.11E+03 E0= -.11E+03  EK= 0.1E+01 SP= 0.0E+00 SK= 0.0E+00
            RMM:   3    -0.111E+03   -0.1E-03   -0.1E-03  1000   0.1E-01

            """;
        var md = Detect(Make("vasp-md", new() { ["INCAR"] = "SYSTEM = test\nIBRION = 0 ; NSW = 500   ! MD\nPOTIM = 1\n", ["OSZICAR"] = oszMD, ["OUTCAR"] = " running on 4 nodes\n" }));
        check(md?.Vasp == VaspMode.Md && md.Current == 2 && md.Total == 500 && md.EndMarker == false, "VASP MD：离子步 / NSW");

        var oszRelax = """
            DAV:   1     0.4E+03    0.4E+03   -0.1E+04  1000   0.1E+02
               1 F= -.43E+03 E0= -.43E+03  d E =-.43E+03  mag=     2.0
            RMM:   5    -0.43E+03   -0.1E-04   -0.1E-04  1000   0.1E-01
               2 F= -.44E+03 E0= -.44E+03  d E =-.1E+01  mag=     2.0
               3 F= -.44E+03 E0= -.44E+03  d E =-.1E-02  mag=     2.0

            """;
        var relax = Detect(Make("vasp-relax", new() { ["INCAR"] = "ibrion=2; nsw=200\nEDIFFG = -0.01 # force\n", ["OSZICAR"] = oszRelax,
                                                      ["OUTCAR"] = "...\n General timing and accounting informations for this job:\n Total CPU time used (sec): 1.0\n" }));
        check(relax?.Vasp == VaspMode.Relax && relax.Current == 3 && relax.Total == null && relax.Fraction == null
              && relax.EndMarker == true && relax.Finished, "VASP 结构优化：只显示离子步（小写、分号、注释）");

        var scf = Detect(Make("vasp-scf", new() { ["INCAR"] = "ENCUT = 500\n", ["OSZICAR"] = "DAV:   1  0.1E+03\nDAV:  11  0.1E+03\nRMM:  12  0.1E+03\n" }));
        check(scf?.Vasp == VaspMode.Scf && scf.Current == 12 && scf.EndMarker == null, "VASP 单点：电子步");

        check(Detect(Make("vasp-phonon", new() { ["INCAR"] = "IBRION = 6\nNSW = 1\n", ["OSZICAR"] = oszRelax })) == null, "VASP 声子（IBRION=6）不识别");
        check(Detect(Make("vasp-md-bad", new() { ["INCAR"] = "IBRION = 0\nNSW = 1\n", ["OSZICAR"] = oszMD })) == null, "VASP MD 离子步超过 NSW 时不显示");

        // MARK: LAMMPS

        var lmpHead = """
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

            """;
        var lmp = Detect(Make("lmp-run", new() { ["log.lammps"] = lmpHead }));
        check(lmp?.Kind == AppKind.Lammps && lmp.Current == 200 && lmp.Total == 1000 && lmp.EndMarker == false, "LAMMPS：最后一段 run 的进度");

        var lmpDone = lmpHead + """
                   1500   300           -3.5            -3.4            12
            Loop time of 12.3 on 4 procs for 1000 steps with 1000 atoms
            Nlocal:           1000 ave        1000 max        1000 min
            Total # of neighbors = 64000
            Total wall time: 0:00:13

            """;
        var done = Detect(Make("lmp-done", new() { ["log.lammps"] = lmpDone }));
        check(done?.Current == 1000 && done.EndMarker == true && done.Finished, "LAMMPS：Total wall time 判定正常结束");

        var lmpMin = lmpDone.Replace("Total wall time: 0:00:13\n", "minimize 1e-6 1e-8 1000 10000\n   Step  Temp  E_pair\n  1500 0 -3.6\n");
        check(Detect(Make("lmp-min", new() { ["log.lammps"] = lmpMin })) == null, "LAMMPS：run 之后接 minimize 时不显示");
        var lmpVar = "LAMMPS\nvariable n equal 1000\nrun ${n}\n   Step Temp\n  0 300\n  100 300\n";
        check(Detect(Make("lmp-var", new() { ["log.lammps"] = lmpVar })) == null, "LAMMPS：run 步数是变量且没有展开时不显示");
        var lmpMulti = "LAMMPS\nthermo_style multi\nrun 1000\n------------ Step              0 ----- CPU =      0.0 (sec) ----\nTotEng   =     -3.4 KinEng   =      0.1\n";
        check(Detect(Make("lmp-multi", new() { ["log.lammps"] = lmpMulti })) == null, "LAMMPS：thermo_style multi 不显示");

        // MARK: 自定义规则

        var kw = new ProgressRule { Name = "PyTorch", File = "*.log", Pattern = "epoch", Unit = "epoch", DoneMarker = "Training finished" };
        var kwDir = Make("custom-kw", new() { ["train.log"] = "Epoch 36/100 loss 0.5\nEpoch 37/100 loss 0.4\nvalidating...\n" });
        var k = Detect(kwDir, [kw]);
        check(k?.Kind == AppKind.Custom && k.Title == "PyTorch" && k.Current == 37 && k.Total == 100 && k.EndMarker == false, "自定义规则：关键字 + 自动识别 a/b");
        check(Detect(kwDir, [kw], builtin: false)?.Current == 37, "自定义规则：只测试这一条（不跑内置识别）");

        var okTest = AppDetectors.InterpretTest(Bash(AppDetectors.RuleTestScript(kwDir, kw)), kw);
        check(okTest.Ok && okTest.Headline.Contains("37") && okTest.Headline.Contains("100"), "测试规则：匹配成功");
        var kwBad = kw.Clone(); kwBad.Pattern = "loss_total";
        var badTest = AppDetectors.InterpretTest(Bash(AppDetectors.RuleTestScript(kwDir, kwBad)), kwBad);
        check(!badTest.Ok && badTest.Lines.Contains("validating..."), "测试规则：没匹配上时给出文件最后几行");
        var kwNoFile = kw.Clone(); kwNoFile.File = "*.csv";
        check(AppDetectors.InterpretTest(Bash(AppDetectors.RuleTestScript(kwDir, kwNoFile)), kwNoFile).Headline.Contains("*.csv"), "测试规则：文件不存在");
        check(AppDetectors.InterpretTest(Bash(AppDetectors.RuleTestScript(kwDir + "/nope", kw)), kw).Headline.Contains("目录"), "测试规则：目录不存在");

        var re = new ProgressRule { Name = "MySim", File = "progress.txt", Match = RuleMatch.Regex, Pattern = @"iter=(\d+).*target=(\d+)" };
        var r = Detect(Make("custom-re", new() { ["progress.txt"] = "start\niter=1234 of target=5000\n" }), [re]);
        check(r?.Current == 1234 && r.Total == 5000, "自定义规则：正则捕获组");

        var tf = new ProgressRule { Name = "Solver", File = "run.log", Pattern = "step", TotalFile = "config.ini", TotalKeyword = "max_steps" };
        var t = Detect(Make("custom-tf", new() { ["run.log"] = "step 100\nstep 120 residual 1e-3\n", ["config.ini"] = "[run]\nmax_steps = 1000\n" }), [tf]);
        check(t?.Current == 120 && t.Total == 1000 && t.EndMarker == null, "自定义规则：从另一个文件读目标值");

        check(Detect(Make("custom-over", new() { ["train.log"] = "Epoch 120/100\n" }), [kw]) == null, "自定义规则：当前值超过目标值时不显示");

        // 自定义规则排在内置识别前面：同一个目录里既有 log.lammps 也匹配规则时，用规则
        var lr = new ProgressRule { Name = "My LAMMPS", File = "log.lammps", Pattern = "run" };
        check(Detect(Make("lmp-rule", new() { ["log.lammps"] = lmpHead }), [lr])?.Kind == AppKind.Custom, "自定义规则优先于内置识别");

        // MARK: 详情页曲线（增量读取）

        var lossDir = Make("curve-nep", new()
        {
            ["loss.out"] = "100 0.30 0.01 0.02 0.20 0.50 0.10 0 0 0\n200 0.20 0.01 0.02 0.10 0.40 0.08 0 0 0\n300 0.15 0.01 0.02 0.08 0.30 0.06 0 0 0\n",
        });
        var lossFile = lossDir + "/loss.out";
        var lossSrc = new AppCurves.Source(lossFile, AppCurves.CurveKind.Loss);
        var cache = AppCurves.Merge(Bash(AppCurves.Script(lossSrc, 0, "")), new CurveCache());
        check(cache?.Rows.Count == 3 && cache.LineCount == 3, "曲线：第一次读取全部行");
        // 追加两行完整的 + 半行（还没写完）
        File.AppendAllText(lossFile, "400 0.12 0.01 0.02 0.07 0.25 0.05 0 0 0\n500 0.10 0.01 0.02 0.06 0.20 0.04 0 0 0\n600 0.0");
        var incOut = Bash(AppCurves.Script(lossSrc, cache?.LineCount ?? 0, cache?.Head ?? ""));
        cache = cache == null ? null : AppCurves.Merge(incOut, cache);
        check(!incOut.Contains("reset=1") && incOut.Split("row=").Length - 1 == 2 && cache?.Rows.Count == 5 && cache.Rows[^1][0] == 500,
              "曲线：增量只读新增的完整行（半行不读）");
        var c = cache == null ? null : AppCurves.Curve(lossSrc, cache.Rows);
        check(c?.LogY == true && c.SeriesList.Select(s => s.Name).SequenceEqual(["Total", "能量", "力", "维里"]) && c.SeriesList[0].Points.Count == 5, "曲线：NEP loss 各列");
        // 重新训练：文件被重写，第一行变了
        File.WriteAllText(lossFile, "100 0.90 0.01 0.02 0.20 0.50 0.10 0 0 0\n200 0.80 0.01 0.02 0.10 0.40 0.08 0 0 0\n");
        cache = cache == null ? null : AppCurves.Merge(Bash(AppCurves.Script(lossSrc, cache.LineCount, cache.Head)), cache);
        check(cache?.Rows.Count == 2 && cache.Rows[0][1] == 0.9, "曲线：文件重写后从头读");

        var oszDir = Make("curve-vasp", new() { ["OSZICAR"] = oszRelax });
        var vSrc = new AppCurves.Source(oszDir + "/OSZICAR", AppCurves.CurveKind.VaspEnergy);
        var vCache = AppCurves.Merge(Bash(AppCurves.Script(vSrc, 0, "")), new CurveCache());
        var vc = vCache == null ? null : AppCurves.Curve(vSrc, vCache.Rows);
        check(vCache?.Rows.Count == 3 && vCache.Rows[^1].SequenceEqual([3.0, -440.0]) && vc?.LogY == false, "曲线：VASP 离子步 E0");
        check(AppCurves.Merge(Bash(AppCurves.Script(new AppCurves.Source(lossDir + "/nope", AppCurves.CurveKind.Loss), 0, "")), new CurveCache()) == null, "曲线：文件不存在");

        // 完整的轮询脚本（含两条规则）语法正确
        var saved = ProgressRule.Active;
        ProgressRule.Active = [kw, tf];
        bool syntaxOK = true;
        foreach (var kind in new[] { HostKind.Slurm, HostKind.Direct })
            if (!SelfTest.Bash(AppDetectors.Script(new HostConfig("x", kind: kind)), "-n").Trim().Equals("")) syntaxOK = false;
        ProgressRule.Active = saved;
        check(syntaxOK, "轮询脚本（含自定义规则）bash 语法检查");

        check(ProgressRule.IsSafeFileName("logs/*.log") && !ProgressRule.IsSafeFileName("a;rm -rf ~")
              && !ProgressRule.IsSafeFileName("../x") && !ProgressRule.IsSafeFileName("$(id)"), "规则文件名只允许安全字符");
    }
}
