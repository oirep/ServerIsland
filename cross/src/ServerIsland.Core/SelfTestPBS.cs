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
            }
            finally { try { Directory.Delete(dir, true); } catch { } }
        }
        check(AppCurves.SourcesFor(new AppProgress { Kind = AppKind.Vasp, Dir = "/d", Vasp = VaspMode.Relax }).Count == 2, "VASP：结构优化有能量和最大力两张图");

        // —— 日志清理 ——
        var now = new DateTime(2026, 10, 17, 12, 0, 0);
        var text = "2026-10-01 10:00:00  old\n  continuation of old\n10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n";
        check(DebugLog.PruneText(text, now.AddDays(-3), now) == "10-16 09:00:00  old format, recent\n2026-10-17 10:00:00  new\n  continuation of new\n",
              "日志：删除早于保留天数的行（续行跟随上一行，旧格式按今年算）");
        check(DebugLog.PruneText("2026-01-01 00:00:00  x\n", now, now).Length == 0, "日志：全部过期时清空");
    }
}
