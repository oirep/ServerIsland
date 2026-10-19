using System.Globalization;
using ServerIsland.Core.Ssh;

namespace ServerIsland.Core;

/// 自检：PBS（用本机 bash + awk 跑真正的转换脚本）、目录过滤、VASP 最大力曲线、日志清理（和 Mac 版 SelfTestPBS.swift 对应）。
public static class SelfTestPBS
{
    /// PBS Pro / OpenPBS 的 `qstat -f -t`：普通作业、被折行的 Variable_List、名字里有 |、数组（父作业 + 子作业）、hold。
    public static readonly string PbsProSample = """
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
        <TAB>R=/home/demo/LLZO/relax,PBS_O_SYSTEM=Linux
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

        """.Replace("<TAB>", "\t");

    /// Torque 和已结束的作业（qstat -x -f）：exit_status 小写、C 状态，PBS Pro 的 F 状态和信号 / 超时。
    public static readonly string EndedSample = """
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

        """;

    /// 一个很小的 NEB 算例（和 Mac 版一样）：2 个中间像点、两个端点都有 OUTCAR、2 个离子步、EDIFFG = -0.05。
    /// 最新一步相对初态：0、0.4、0.3、-0.1 → 能垒 0.4、逆向 0.5；第 1 步能垒 0.5；像点 2 的力 0.07 高于目标。
    public static void MakeNebFixture(string dir)
    {
        void W(string rel, string text) { var f = Path.Combine(dir, rel); Directory.CreateDirectory(Path.GetDirectoryName(f)!); File.WriteAllText(f, text); }
        static string Outcar(double e, double f) => string.Format(CultureInfo.InvariantCulture,
            "  energy  without entropy=     {0:F8}  energy(sigma->0) =     {1:F8}\n  FORCES: max atom, RMS     {2:F6}    0.001000\n", e - 0.01, e, f);
        static string Osz(params double[] es) => string.Concat(es.Select((e, i) => string.Format(CultureInfo.InvariantCulture,
            "DAV:   1    {0:E12}    0.1E-02\n{1,4} F= {0:E8} E0= {0:E8}  d E =-.1E-02\n", e, i + 1)));
        W("INCAR", "SYSTEM = neb\nIBRION = 3\nNSW = 50\nEDIFFG = -0.05\nIMAGES = 2 ! two images\n");
        W("00/OUTCAR", Outcar(-10.0, 0.01));
        W("01/OSZICAR", Osz(-9.5, -9.6)); W("01/OUTCAR", Outcar(-9.6, 0.04));
        W("02/OSZICAR", Osz(-9.8, -9.7)); W("02/OUTCAR", Outcar(-9.7, 0.07));
        W("03/OUTCAR", Outcar(-10.1, 0.02));
    }

    static void NebChecks(Action<bool, string> check)
    {
        var dir = Path.Combine(Path.GetTempPath(), "si-neb-" + Environment.ProcessId);
        try
        {
            MakeNebFixture(dir);
            string ToBash(string p) => OperatingSystem.IsWindows() ? "/" + p[0].ToString().ToLowerInvariant() + p[2..].Replace('\\', '/') : p;
            var bdir = ToBash(dir);
            var det = AppDetectors.Parse(SelfTest.Bash(AppDetectors.DirectoryScript("7", bdir, [], true)).Split('\n')).GetValueOrDefault("7");
            check(det?.Vasp == VaspMode.Neb && det.Current == 2 && Math.Abs((det.NebBarrier ?? 0) - 0.4) < 1e-6 && det.NebForce == 0.07,
                  "NEB：识别 IMAGES 和 01/OSZICAR，离子步、能垒（最高像点 − 00）、中间像点的最大 VTST 力");
            check(det?.Summary.Contains("0.400 eV") == true, "NEB：任务行显示能垒和最大力");
            var src = new AppCurves.Source(bdir, AppCurves.CurveKind.Neb);
            var merged = AppCurves.Merge(SelfTest.Bash(AppCurves.Script(src, 0, "")), new CurveCache());
            var cs = merged == null ? [] : AppCurves.Curves(src, merged.Rows, merged.Extra);
            var prof = cs.FirstOrDefault();
            check(cs.Count == 2 && prof!.SeriesList[0].Points.Select(p => Math.Round(p.Y, 3)).SequenceEqual([0, 0.4, 0.3, -0.1]),
                  "NEB：能垒图用最新一步的中间像点 + 端点 OUTCAR 的能量，相对初态");
            check(prof != null && prof.Bars.Select(b => b.Y).SequenceEqual([0.04, 0.07]) && prof.Threshold == 0.05 && cs.Count == 2
                  && cs[1].Note?.Contains("0.400") == true && cs[1].Note?.Contains("0.500") == true,
                  "NEB：柱子是每个中间像点的力，虚线是 |EDIFFG|，能垒图旁边写正向 / 逆向能垒");
            check(cs.Count == 2 && cs[1].SeriesList[0].Points.Select(p => Math.Round(p.Y, 3)).SequenceEqual([0.5, 0.4]), "NEB：能垒随离子步的变化");
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    public static void Run(Action<bool, string> check, bool hasBash)
    {
        if (hasBash)
        {
            // —— PBS ——
            string Si(string mode, string sample) => SelfTest.Bash(RemoteScript.PbsFunction + $"si_pbs {mode} <<'SI_EOF'\n" + sample + "SI_EOF\n");
            var q = Si("q", PbsProSample);
            var qLines = q.Split('\n').Where(l => l.Length > 0).ToList();
            check(qLines.FirstOrDefault() == "1001|relax_LLZO|RUNNING|01:02:03|24:00:00|2|cn01,cn02|workq|1001|N/A",
                  "PBS：运行中的作业转换成 squeue 格式（节点去重、续行拼接）");
            check(qLines.Count == 5 && !q.Contains("1003[]") && !q.Contains("1003_1|"), "PBS：跳过数组父作业和已结束的子作业");
            var jobs = Parsers.GroupArrays(Parsers.Squeue(qLines));
            var pend = jobs.FirstOrDefault(j => j.Id == "1002");
            check(pend?.State == JobState.Pending && pend.Name == "md/300K" && pend.Reason == "Not Running: Insufficient amount of resource: ncpus",
                  "PBS：排队作业的原因来自 comment，名称里的 | 不会打乱列");
            var arr = jobs.FirstOrDefault(j => j.Id == "1003");
            check(arr?.Array?.Running.Count == 1 && arr.Array.Pending == 1 && arr.Array.Running[0].Id == "1003_2", "PBS：数组子作业 1003[2] 写成 1003_2 并合并成一行");
            check(jobs.FirstOrDefault(j => j.Id == "1004")?.Reason?.StartsWith("JobHeldUser") == true, "PBS：H 状态显示为被挂起");
            var j1 = jobs.FirstOrDefault(j => j.Id == "1001");
            check(j1?.Elapsed == 3723 && j1.Limit == 86400, "PBS：已运行和时间上限");

            var finals = Parsers.Sacct(Si("a", EndedSample).Split('\n'));
            check(finals.GetValueOrDefault("2001")?.State == JobState.Completed && finals.GetValueOrDefault("2002")?.State == JobState.Failed
                  && finals.GetValueOrDefault("2003")?.State == JobState.Cancelled && finals.GetValueOrDefault("2004")?.State == JobState.Timeout
                  && finals.GetValueOrDefault("2001")?.Elapsed == 18000, "PBS：结束状态（Torque 的 C / exit_status，PBS Pro 的 F，信号终止、超时）");

            var d = SelfTest.Bash($"printf '{RemoteScript.Marker}HOME /home/demo\\n'\n" + RemoteScript.PbsFunction + "si_pbs d <<'SI_EOF'\n" + PbsProSample + "SI_EOF\n");
            var (home, dirs) = Parsers.Workdirs(d.Split('\n'));
            check(home == "/home/demo" && dirs.GetValueOrDefault("1001") == "/home/demo/LLZO/relax" && dirs.GetValueOrDefault("1003_2") == "/home/demo/LLZO/scan"
                  && dirs.GetValueOrDefault("1002") == "/home/demo/other", "PBS：每个作业的工作目录（PBS_O_WORKDIR）");
            var w = Si("w", PbsProSample);
            check(w.Contains("1001|/home/demo/LLZO/relax") && !w.Contains("1002|"), "PBS：计算软件识别只取运行中作业的目录");
        }
        else check(true, "PBS 转换脚本（没有 bash，跳过）");

        var kv = Parsers.PbsKeyValues(PbsProSample.Split('\n'));
        check(kv.GetValueOrDefault("Job_Name") == "relax_LLZO" && kv.GetValueOrDefault("PBS_O_WORKDIR") == "/home/demo/LLZO/relax"
              && kv.GetValueOrDefault("exec_host") == "cn01/0*8+cn02/0*8", "PBS：详情页解析 qstat -f（含续行）");
        check(RemoteScript.PbsID("1003_2") == "1003[2]" && RemoteScript.PbsID("1001") == "1001", "PBS：作业号换回 PBS 的写法");

        var pbs = new HostConfig("x", kind: HostKind.Pbs) { AllowCancel = true, PathFilter = "~/LLZO", SlurmAlsoProcesses = true };
        var pj = new RemoteJob("1003_2", "it's \"scan\"", JobState.Running, JobSource.Slurm);
        string[] scripts =
        [
            RemoteScript.Build(pbs), RemoteScript.DetailScript(pbs, pj), RemoteScript.CancelScript(pbs, pj, null, false)!,
            RemoteScript.SacctScript(pbs, ["1003_2", "1001"]), AppDetectors.Script(pbs),
            RemoteScript.Build(new HostConfig("x", kind: HostKind.Slurm) { PathFilter = "/data" }),
        ];
        if (hasBash) check(scripts.All(s => SelfTest.BashSyntax(s).Code == 0), "PBS：列表 / 详情 / 取消 / 结束状态 / 目录过滤脚本 bash 语法正确");
        check(scripts[2].Contains("qdel '1003[2]'") && scripts[3].Contains("qstat -x -f -t '1003[2]' '1001'"), "PBS：取消和结束状态用 PBS 的作业号");

        // —— 目录过滤 ——
        check(Parsers.PathMatches("/home/demo/LLZO/relax", ["~/LLZO"], "/home/demo")
              && Parsers.PathMatches("/home/demo/LLZO", ["/home/demo/LLZO/"], null)
              && !Parsers.PathMatches("/home/demo/LLZO2/x", ["/home/demo/LLZO"], null)
              && !Parsers.PathMatches("/home/demo/other", ["~/LLZO", "/scratch"], "/home/demo"),
              "目录过滤：子目录算在内，同名前缀（LLZO2）不算，~ 按远端家目录展开");
        check(new HostConfig("x") { PathFilter = "~/LLZO\n /scratch/demo ,\n\n" }.PathPrefixes.SequenceEqual(["~/LLZO", "/scratch/demo"]), "目录过滤：每行一个（也认逗号），去掉空行");

        // —— VASP 最大力 ——
        if (hasBash)
        {
            var dir = Path.Combine(Path.GetTempPath(), "si-force-" + Environment.ProcessId);
            Directory.CreateDirectory(dir);
            try
            {
                var dash = " " + new string('-', 83);
                string Block(params (double, double, double)[] f) =>
                    " POSITION                                       TOTAL-FORCE (eV/Angst)\n" + dash + "\n"
                    + string.Join("\n", f.Select(x => string.Format(CultureInfo.InvariantCulture, "      0.00000      0.00000      0.00000     {0,12:F6} {1,12:F6} {2,12:F6}", x.Item1, x.Item2, x.Item3)))
                    + "\n" + dash + "\n    total drift:                                0.000000     0.000000     0.000000\n";
                var outcar = Path.Combine(dir, "OUTCAR");
                File.WriteAllText(outcar, " vasp.6.4.2 18Apr23\n" + Block((0.3, 0.4, 0), (-0.1, 0, 0)) + Block((0.03, 0, 0.04), (0, 0, 0.01))
                    + " POSITION                                       TOTAL-FORCE (eV/Angst)\n" + dash + "\n      0.0 0.0 0.0  0.2 0.0 0.0\n");
                File.WriteAllText(Path.Combine(dir, "INCAR"), "SYSTEM = test\n  EDIFFG = -0.02   ! force\nIBRION = 2\n");
                // Windows 上 Git Bash 用 /c/... 形式的路径
                var bashPath = OperatingSystem.IsWindows() ? "/" + outcar[0].ToString().ToLowerInvariant() + outcar[2..].Replace('\\', '/') : outcar;
                var src = new AppCurves.Source(bashPath, AppCurves.CurveKind.VaspForce);
                var c1 = AppCurves.Merge(SelfTest.Bash(AppCurves.Script(src, 0, "")), new CurveCache());
                var curve1 = c1 == null ? null : AppCurves.Curve(src, c1.Rows, c1.Extra);
                check(c1?.Rows.Count == 2 && Math.Abs(c1.Rows[0][1] - 0.5) < 1e-6 && Math.Abs(c1.Rows[1][1] - 0.05) < 1e-6, "VASP：每个离子步的最大力 |F|（OUTCAR 的 TOTAL-FORCE 块）");
                check(curve1?.Threshold == 0.02 && curve1.LogY && curve1.SeriesList[0].Points[^1].X == 2, "VASP：EDIFFG < 0 时画出收敛目标");
                File.AppendAllText(outcar, dash + "\n");
                var c2 = c1 == null ? null : AppCurves.Merge(SelfTest.Bash(AppCurves.Script(src, c1.LineCount, c1.Head)), c1);
                check(c2?.Rows.Count == 3 && Math.Abs(c2.Rows[^1][1] - 0.2) < 1e-6, "VASP：增量读取时不丢写到一半的力块");
                check(curve1?.SeriesList.Count == 2 && curve1.SeriesList[1].Faint && Math.Abs(curve1.SeriesList[1].Points[^1].Y - 0.05) < 1e-9, "VASP：再画一条只降不升的“最低”线");
                // OUTCAR 里 VASP 实际用的 EDIFFG 优先于 INCAR（这里是默认值 0.001：按能量收敛，没有目标线，写一句说明）
                File.AppendAllText(outcar, "   EDIFFG = 0.1E-02   stopping-criterion for IOM\n");
                var c3 = AppCurves.Merge(SelfTest.Bash(AppCurves.Script(src, 0, "")), new CurveCache());
                var curve3 = c3 == null ? null : AppCurves.Curve(src, c3.Rows, c3.Extra);
                check(curve3 != null && curve3.Threshold == null && curve3.Note?.Contains("0.0010") == true, "VASP：按能量收敛时不画目标线，写明 ΔE 判据（EDIFFG 从 OUTCAR 读）");
                // 固定原子（POSCAR 的 Selective dynamics）不算：第一个原子三个方向都固定，只看第二个
                var sdDir = Path.Combine(dir, "sd");
                Directory.CreateDirectory(sdDir);
                File.WriteAllText(Path.Combine(sdDir, "OUTCAR"), "SYSTEM\n" + Block((0.3, 0.4, 0), (-0.1, 0, 0)) + Block((0.03, 0, 0.04), (0, 0, 0.01)));
                File.WriteAllText(Path.Combine(sdDir, "POSCAR"), "mol\n1.0\n10 0 0\n0 10 0\n0 0 10\nH\n2\nSelective dynamics\nDirect\n0.1 0.1 0.1 F F F\n0.2 0.2 0.2 T T T\n");
                string ToBash(string p) => OperatingSystem.IsWindows() ? "/" + p[0].ToString().ToLowerInvariant() + p[2..].Replace('\\', '/') : p;
                var sdSrc = new AppCurves.Source(ToBash(Path.Combine(sdDir, "OUTCAR")), AppCurves.CurveKind.VaspForce);
                var sd = AppCurves.Merge(SelfTest.Bash(AppCurves.Script(sdSrc, 0, "")), new CurveCache());
                check(sd != null && sd.Rows.Select(r => r[1]).SequenceEqual([0.1, 0.01]), "VASP：Selective dynamics 固定的方向不算进最大力");
                // VTST 的 FORCES: max atom 优先；块之后才写出来的 VTST 行，增量读取时只算一次
                var vtDir = Path.Combine(dir, "vtst");
                Directory.CreateDirectory(vtDir);
                var vtOut = Path.Combine(vtDir, "OUTCAR");
                File.WriteAllText(vtOut, "SYSTEM\n" + Block((0.3, 0.4, 0)) + string.Format("  FORCES: max atom, RMS     {0}    0.004290\n", "0.0213") + Block((0.1, 0, 0)));
                var vtSrc = new AppCurves.Source(ToBash(vtOut), AppCurves.CurveKind.VaspForce);
                var v1 = AppCurves.Merge(SelfTest.Bash(AppCurves.Script(vtSrc, 0, "")), new CurveCache());
                File.AppendAllText(vtOut, string.Format("  FORCES: max atom, RMS     {0}    0.004290\n", "0.0105"));
                var v2 = v1 == null ? null : AppCurves.Merge(SelfTest.Bash(AppCurves.Script(vtSrc, v1.LineCount, v1.Head)), v1);
                var vCurve = v2 == null ? null : AppCurves.Curve(vtSrc, v2.Rows, v2.Extra);
                check(v2 != null && v2.Rows.Where(r => r[0] == 1).Select(r => r[1]).SequenceEqual([0.0213, 0.0105])
                      && vCurve != null && vCurve.SeriesList[0].Points.Select(p => p.Y).SequenceEqual([0.0213, 0.0105]),
                      "VASP：有 VTST 时用它的 max atom（和 grep RMS 一致），增量读取不重复");
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }
        check(AppCurves.SourcesFor(new AppProgress { Kind = AppKind.Vasp, Dir = "/d", Vasp = VaspMode.Relax }).Count == 2, "VASP：结构优化有能量和最大力两张图");

        // —— NEB ——
        if (hasBash) NebChecks(check);

        // —— 检查更新 ——
        check(UpdateChecker.Compare("0.10.0", "0.9.1") == 1 && UpdateChecker.Compare("0.2", "0.2.0") == 0
              && UpdateChecker.Compare("0.2.0", "0.2.1") == -1 && UpdateChecker.Compare("1.0.0-beta", "1.0.0") == 0, "更新：版本号按数字逐段比较");
        const string rel = """{"tag_name":"v0.3.0","html_url":"https://github.com/zhyan0603/ServerIsland/releases/tag/v0.3.0","body":"## What's new\r\n\r\n- PBS\r\n- Folder filter","assets":[{"name":"ServerIsland-0.3.0-win-x64.zip","browser_download_url":"https://example.org/w.zip"},{"name":"ServerIsland-0.3.0.dmg","browser_download_url":"https://example.org/m.dmg"}]}""";
        var parsed = UpdateChecker.Parse(rel, ".dmg");
        check(parsed?.Version == "0.3.0" && parsed.DownloadUrl == "https://example.org/m.dmg" && parsed.Notes == "- PBS\n- Folder filter"
              && UpdateChecker.Parse(rel, "win-x64.zip")?.DownloadUrl == "https://example.org/w.zip", "更新：解析 GitHub Release（去掉 v、选对安装包、说明跳过标题）");
        check(UpdateChecker.Parse("""{"tag_name":"v1","html_url":"https://x.org/r","assets":[]}""", ".dmg")?.DownloadUrl == "https://x.org/r", "更新：没有对应安装包时打开 Release 页面");
        var withDigest = """{"tag_name":"v0.3.0","html_url":"https://x.org/r","assets":[{"name":"ServerIsland-0.3.0.dmg","browser_download_url":"https://x.org/m.dmg","size":5213343,"digest":"sha256:4FE94B94"},{"name":"ServerIsland-0.3.0-win-x64.zip","browser_download_url":"https://x.org/w.zip","digest":"md5:1"}]}""";
        var dmgRel = UpdateChecker.Parse(withDigest, ".dmg");
        check(dmgRel?.Digest == "4fe94b94" && dmgRel.Size == 5213343 && UpdateChecker.Parse(withDigest, "win-x64.zip")?.Digest == null
              && parsed?.Digest == null && UpdateInstaller.UnsupportedReason(parsed!) != null,
              "更新：取出安装包的 SHA-256（不是 sha256 的不用；没有校验信息时不自动安装）");
        check(UpdateChecker.Summary("<p align=\"center\">\n<img src=\"x\">\n</p>\n<h1>v1</h1>\nIntro line\n- **A**: one\n- B") == "- **A**: one\n- B",
              "更新：说明摘要跳过 HTML，优先取列表项");

        // —— 日志清理 ——
        var now = new DateTime(2026, 10, 17, 12, 0, 0);
        var text = "2026-10-01 10:00:00  old\n  continuation of old\n10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n";
        check(DebugLog.PruneText(text, now.AddDays(-3), now) == "10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n",
              "日志：删除早于保留天数的行（续行跟随上一行，旧格式按今年算）");
        check(DebugLog.PruneText("2026-01-01 00:00:00  x\n", now, now).Length == 0, "日志：全部过期时清空");
    }
}
