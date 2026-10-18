using ServerIsland.Core.Ssh;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 任务详情（只在用户点开时按需查询）。
public sealed class JobDetail
{
    public sealed class LogTail
    {
        public string? Path;
        public List<string> Lines = [];
        /// 读不到日志时的说明（如"输出到终端"、"没有读取权限"）。
        public string? Note;
    }

    public List<(string Key, string Value)> Fields = [];
    public LogTail Stdout = new();
    public LogTail? Stderr;
    public string? Error;
    public DateTime FetchedAt = DateTime.Now;
}

public sealed record CancelOutcome(bool Done, string Message);

public sealed partial class MonitorEngine
{
    // MARK: - 详情

    bool IsDemo(HostConfig host) => Demo && DemoData.IsDemoHost(host);

    public async Task<JobDetail> FetchDetail(HostConfig host, RemoteJob job)
    {
        if (IsDemo(host)) { await Task.Delay(300); return DemoData.Detail(job); }
        var d = new JobDetail();
        if (job.Source == JobSource.ProgressFile)
        {
            d.Fields.Add((L("名称", "Name"), job.Name));
            if (job.Message != null) d.Fields.Add((L("进度说明", "Progress"), job.Message));
            d.Stdout.Note = L("进度文件条目没有对应的进程或作业", "Progress-file entries have no process or job");
            return d;
        }
        var r = await Run(host, RemoteScript.DetailScript(host, job), 20);
        if (SshCommon.Classify(r, host) is { } problem)
        {
            d.Error = problem.Message;
            return d;
        }
        var p = RemoteScript.Parse(r.Stdout);
        if (job.Source == JobSource.Slurm && host.Kind == HostKind.Pbs) FillPbs(d, p);
        else if (job.Source == JobSource.Slurm) FillSlurm(d, p, job);
        else FillProcess(d, p);
        d.Stdout = LogTailOf(p.Get("stdout"));
        if (p.Get("stderr") is { } e && e.Lines.Any(l => l.StartsWith(RemoteScript.Marker + "PATH"))) d.Stderr = LogTailOf(e);
        if (d.Stdout.Path == null && d.Stdout.Note == null)
            d.Stdout.Note = job.Source != JobSource.Slurm ? L("没有找到日志", "No log found")
                : host.Kind == HostKind.Pbs ? L("没有找到输出文件（PBS 常在作业结束后才把输出拷回来）", "No output file yet (PBS often copies it back only when the job ends)")
                : L("没有找到 StdOut 路径（作业可能已结束太久）", "No StdOut path found (the job may have ended too long ago)");
        return d;
    }

    static void FillSlurm(JobDetail d, RemoteScript.Parsed p, RemoteJob job)
    {
        if (p.Get("scontrol") is { ExitCode: 0 } sec && sec.Lines.FirstOrDefault(l => l.Contains("JobId=")) is { } line)
        {
            var kv = Parsers.KeyValues(line);
            (string, string)[] keys =
            [
                ("JobState", L("状态", "State")), ("Reason", L("原因", "Reason")), ("RunTime", L("已运行", "Elapsed")), ("TimeLimit", L("时间上限", "Time limit")),
                ("SubmitTime", L("提交时间", "Submitted")), ("StartTime", L("开始时间", "Started")), ("Partition", L("分区", "Partition")), ("NodeList", L("节点", "Nodes")),
                ("NumCPUs", "CPU"), ("TRES", L("资源", "Resources")), ("WorkDir", L("工作目录", "Directory")), ("ExitCode", L("退出码", "Exit code")),
            ];
            foreach (var (k, label) in keys)
            {
                if (!kv.TryGetValue(k, out var v) || v.Length == 0 || v is "(null)" or "None" or "Unknown") continue;
                if (k is "TRES" or "AllocTRES") v = v.Replace("billing=", "");
                d.Fields.Add((label, v));
            }
        }
        else if (p.Get("sacct") is { } s2 && s2.Lines.FirstOrDefault(l => l.StartsWith(job.Id)) is { } l2)
        {
            // 已经结束太久，scontrol 查不到了，用 sacct。
            var f = l2.Split('|');
            string[] labels = [L("作业号", "Job ID"), L("名称", "Name"), L("分区", "Partition"), L("状态", "State"), L("退出码", "Exit code"), L("用时", "Elapsed"),
                               L("开始时间", "Started"), L("结束时间", "Ended"), L("节点", "Nodes"), L("资源", "Resources"), L("峰值内存", "Peak memory")];
            for (int i = 2; i < labels.Length && i < f.Length; i++)
                if (f[i].Length > 0) d.Fields.Add((labels[i], f[i]));
        }
        else d.Error = L("scontrol / sacct 都查不到这个作业", "Neither scontrol nor sacct knows this job");
    }

    /// PBS：`qstat -f` 的 key = value（续行以 Tab 开头）。
    static void FillPbs(JobDetail d, RemoteScript.Parsed p)
    {
        if (p.Get("qstat") is not { } sec || !sec.Lines.Any(l => l.StartsWith("Job Id:", StringComparison.Ordinal)))
        {
            d.Error = L("qstat 查不到这个作业（可能已经结束太久）", "qstat doesn't know this job (it may have ended too long ago)");
            return;
        }
        var kv = Parsers.PbsKeyValues(sec.Lines);
        var states = new Dictionary<string, string>
        {
            ["Q"] = L("排队", "Queued"), ["R"] = L("运行中", "Running"), ["H"] = L("挂起（hold）", "Held"), ["E"] = L("收尾", "Exiting"),
            ["W"] = L("等待开始时间", "Waiting"), ["S"] = L("暂停", "Suspended"), ["B"] = L("数组运行中", "Array running"),
            ["F"] = L("已结束", "Finished"), ["X"] = L("已结束", "Finished"), ["C"] = L("已结束", "Completed"), ["T"] = L("转移中", "Moving"),
        };
        (string Key, string Label)[] keys =
        [
            ("job_state", L("状态", "State")), ("comment", L("说明", "Comment")), ("resources_used.walltime", L("已运行", "Elapsed")),
            ("Resource_List.walltime", L("时间上限", "Time limit")), ("qtime", L("提交时间", "Submitted")), ("stime", L("开始时间", "Started")),
            ("queue", L("队列", "Queue")), ("exec_host", L("节点", "Nodes")), ("Resource_List.select", L("资源", "Resources")),
            ("Resource_List.nodes", L("资源", "Resources")), ("Resource_List.ncpus", "CPU"), ("resources_used.mem", L("内存", "Memory")),
            ("PBS_O_WORKDIR", L("工作目录", "Directory")), ("Exit_status", L("退出码", "Exit code")), ("exit_status", L("退出码", "Exit code")),
        ];
        var seen = new HashSet<string>();
        foreach (var (k, label) in keys)
        {
            if (!kv.TryGetValue(k, out var v) || v.Length == 0 || !seen.Add(label)) continue;
            if (k == "job_state" && states.TryGetValue(v, out var st)) v = $"{st} ({v})";
            if (k == "exec_host") v = string.Join(",", v.Split('+').Select(x => x.Split('/')[0]).Where(x => x.Length > 0).Distinct());
            d.Fields.Add((label, v));
        }
    }

    static void FillProcess(JobDetail d, RemoteScript.Parsed p)
    {
        if (p.Get("ps") is not { } ps || ps.Lines.FirstOrDefault(l => l.TrimWs().Length > 0) is not { } line)
        {
            d.Error = L("进程已经结束", "The process has ended");
            return;
        }
        var f = Text.Words(line);
        if (f.Count >= 8)
        {
            d.Fields.Add((L("PID / 父进程", "PID / parent"), $"{f[0]} / {f[1]}"));
            d.Fields.Add((L("用户", "User"), f[2]));
            if (Text.Dbl(f[3]) is { } e) d.Fields.Add((L("已运行", "Elapsed"), Format.Duration(e)));
            d.Fields.Add((L("CPU / 内存", "CPU / MEM"), $"{f[4]}% / {f[5]}%"));
            if (Text.Dbl(f[6]) is { } rss) d.Fields.Add((L("常驻内存", "RSS"), Format.Bytes(rss * 1024)));
            d.Fields.Add((L("状态", "State"), f[7]));
        }
        if (p.Get("gpu")?.Lines.FirstOrDefault(l => l.Contains(',')) is { } g)
        {
            var mem = g.Split(',').Last().TrimWs();
            if (Text.Dbl(mem) is { } mb) d.Fields.Add((L("显存", "VRAM"), Format.Bytes(mb * 1_048_576)));
        }
        if (p.Get("cwd")?.Lines.FirstOrDefault(l => l.Length > 0) is { } cwd) d.Fields.Add((L("工作目录", "Directory"), cwd));
        if (p.Get("args")?.Lines.FirstOrDefault(l => l.Length > 0) is { } args) d.Fields.Add((L("命令", "Command"), args));
    }

    static JobDetail.LogTail LogTailOf(RemoteScript.Section? sec)
    {
        var t = new JobDetail.LogTail();
        if (sec == null) return t;
        foreach (var line in sec.Lines)
        {
            if (line.StartsWith(RemoteScript.Marker + "PATH ")) t.Path = line[(RemoteScript.Marker + "PATH ").Length..];
            else if (line == RemoteScript.Marker + "UNREADABLE") t.Note = L("日志文件不存在或没有读取权限", "Log file missing or not readable");
            else if (line.StartsWith(RemoteScript.Marker + "NOFILE"))
            {
                var target = line[(RemoteScript.Marker + "NOFILE").Length..].TrimWs();
                t.Note = target.Contains("pts") || target.Contains("tty")
                    ? L("输出直接打印到终端（tmux / screen），读不到日志；可以用 > log.txt 重定向", "Output goes to a terminal (tmux / screen); redirect with > log.txt to see it here")
                    : target.Length == 0 ? L("读不到这个进程的输出（可能不属于你）", "Cannot read this process output (it may not be yours)")
                    : L($"输出到 {target}，不是文件", $"Output goes to {target}, not a file");
            }
            else t.Lines.Add(line);
        }
        while (t.Lines.Count > 0 && t.Lines[^1].Length == 0) t.Lines.RemoveAt(t.Lines.Count - 1);
        return t;
    }

    // MARK: - 取消

    public async Task<CancelOutcome> Cancel(HostConfig host, RemoteJob job, DateTime? sampledAt, bool force)
    {
        if (IsDemo(host)) return new(false, L("演示模式不会执行任何命令", "Demo mode doesn't run anything"));
        if (!host.AllowCancel) return new(false, L("这台服务器没有开启「允许取消任务」", "“Allow Cancelling” is off for this server"));
        double? expected = job.Elapsed is { } e ? e + (sampledAt is { } s ? (DateTime.Now - s).TotalSeconds : 0) : null;
        if (RemoteScript.CancelScript(host, job, expected, force) is not { } script)
            return new(false, L("这个条目不能取消", "This entry cannot be cancelled"));
        var r = await Run(host, script, 20);
        if (SshCommon.Classify(r, host) is { } problem) return new(false, problem.Message);
        var o = r.Stdout;
        if (o.Split('\n').FirstOrDefault(l => l.StartsWith(RemoteScript.Marker + "ABORT")) is { } abort)
            return new(false, abort.Length > (RemoteScript.Marker + "ABORT ").Length ? abort[(RemoteScript.Marker + "ABORT ").Length..] : abort);
        if (o.Contains(RemoteScript.Marker + "DONE"))
        {
            Refresh(host.Id);
            var what = job.Source == JobSource.Slurm ? $"{host.Kind.CancelCommand()} {job.Id}" : $"kill -{(force ? "KILL" : "TERM")} {job.Id}";
            return new(true, L($"已执行 {what}", $"Ran {what}"));
        }
        var err = (r.Stderr + o).Split('\n').FirstOrDefault(l => l.Length > 0 && !l.StartsWith(RemoteScript.Marker)) ?? L("未知错误", "Unknown error");
        return new(false, err);
    }

    // MARK: - 最近 24 小时

    /// Slurm 优先用 sacct（服务器上的完整记录）；不支持时退回到本机观察到的记录。
    public async Task<(List<HistoryEntry> Entries, bool FromServer)> FetchHistory(HostConfig host)
    {
        if (IsDemo(host)) { await Task.Delay(300); return (host.Kind == HostKind.Slurm ? DemoData.History() : [], host.Kind == HostKind.Slurm); }
        var local = History.Entries(host.Id);
        if (host.Kind != HostKind.Slurm || SacctUnsupported.Contains(host.Id)) return (local, false);
        var r = await Run(host, RemoteScript.HistoryScript(host), 25);
        if (RemoteScript.Parse(r.Stdout).Get("history") is not { ExitCode: 0 } sec)
        {
            if (r.Status != 255) SacctUnsupported.Add(host.Id);   // 命令本身不可用：本次运行内不再尝试
            return (local, false);
        }
        return (HistoryStore.Merge(Parsers.History(sec.Lines), local), true);
    }

    // MARK: - 监听进程

    public async Task<List<RemoteJob>?> TopProcesses(HostConfig host)
    {
        if (IsDemo(host)) { await Task.Delay(300); return Snapshots.GetValueOrDefault(host.Id)?.Jobs.Select(j => j.Clone()).ToList() ?? []; }
        var r = await Run(host, RemoteScript.TopProcessesScript(host), 20);
        var p = RemoteScript.Parse(r.Stdout);
        if (p.Get("procs") is not { } sec) return null;
        var gpu = p.Get("gpuapps") is { } g ? Parsers.GpuApps(g.Lines) : [];
        // 这里不套用"包含"过滤，但仍然去掉系统 / 桌面进程。
        return Parsers.Processes(sec.Lines, "", host.ProcessExclude, gpu)
            .OrderByDescending(j => j.GpuMemoryMB ?? 0).ThenByDescending(j => j.CpuPercent ?? 0).Take(12).ToList();
    }

    public bool IsWatched(Guid hostID, string pid) => Store.Host(hostID)?.Watched.Any(w => w.Pid == pid) ?? false;

    public void Watch(Guid hostID, RemoteJob job)
    {
        if (Store.Host(hostID) is not { } h || h.Watched.Any(w => w.Pid == job.Id)) return;
        h.Watched.Add(new WatchedProcess { Pid = job.Id, Name = job.Name, StartedAt = job.Elapsed is { } e ? DateTime.Now.AddSeconds(-e) : null });
        Store.Touch();
    }

    public void Unwatch(Guid hostID, string pid)
    {
        if (Store.Host(hostID) is not { } h) return;
        h.Watched.RemoveAll(w => w.Pid == pid);
        Store.Touch();
    }

    /// 弹窗登录（经跳板机时每一跳分别询问），成功后立即刷新。返回 null 表示成功。
    public async Task<string?> Login(HostConfig host, ILoginPrompter prompter)
    {
        if (IsDemo(host)) return L("演示模式不会连接服务器", "Demo mode doesn't connect to servers");
        LoggingIn.Add(host.Id);
        NotifyChanged();
        try
        {
            var err = await Ssh.LoginAsync(host, prompter);
            ApplyRemember();
            DebugLog.Log($"[{host.DisplayName}] 弹窗登录：{err ?? "成功"}");
            if (err == null) RefreshAfterLogin(host.Id);
            return err;
        }
        finally
        {
            LoggingIn.Remove(host.Id);
            NotifyChanged();
        }
    }

    readonly Dictionary<Guid, DateTime> _lastAutoLogin = [];

    /// 后台用记住的密码重新登录（不弹窗）。同一台机器 10 分钟内最多试一次，避免密码错了被服务器锁定。
    public async void AutoRelogin(HostConfig host)
    {
        if (IsDemo(host) || !host.Auth.CanRemember() || !host.RememberPassword || LoggingIn.Contains(host.Id)) return;
        if (_lastAutoLogin.TryGetValue(host.Id, out var t) && DateTime.Now - t < TimeSpan.FromMinutes(10)) return;
        _lastAutoLogin[host.Id] = DateTime.Now;
        if (!await Task.Run(() => Core.Ssh.CredentialStore.Has(host.Id))) return;
        // 连接还在（比如是经它跳转的机器出了问题）就不用重新登录
        if (await Ssh.IsLoggedInAsync(host)) return;
        LoggingIn.Add(host.Id);
        try
        {
            var err = await Ssh.AutoLoginAsync(host);
            DebugLog.Log($"[{host.DisplayName}] 自动重新登录：{err ?? "成功"}");
            if (err == null) RefreshAfterLogin(host.Id);
        }
        finally { LoggingIn.Remove(host.Id); }
    }

    /// 登录成功：刷新它，以及经它跳转、正处于异常状态的机器。
    void RefreshAfterLogin(Guid id)
    {
        Refresh(id);
        foreach (var h in Store.Settings.Hosts.Where(h => h.Enabled && h.Id != id
                     && Core.Ssh.SshHosts.JumpChain(h).Any(j => j.Id == id)
                     && Snapshots.GetValueOrDefault(h.Id)?.Health.IsProblem == true))
            Refresh(h.Id);
    }

    /// 弹窗里勾选 / 取消"记住密码"后同步到设置。
    void ApplyRemember()
    {
        bool changed = false;
        foreach (var (id, on) in Ssh.TakeRememberChoices())
            if (Store.Host(id) is { } h && h.RememberPassword != on) { h.RememberPassword = on; changed = true; }
        if (changed) Store.Touch();
    }

    /// 设置页"检查命令"：在当前环境（含"连接后先执行"和补全 PATH）下查找常用命令。
    public async Task<List<(string Name, string? Path)>> CheckEnvironment(HostConfig host)
    {
        string[] names = ["squeue", "sinfo", "sacct", "nvidia-smi", "gpumd", "nep"];
        var script = host.Commands.Preamble.Length == 0 ? "" : host.Commands.Preamble + "\n";
        script += $"for c in {string.Join(" ", names)}; do printf '%s=%s\\n' \"$c\" \"$(command -v $c 2>/dev/null)\"; done\n";
        var r = await Run(host, script, 20);
        var found = new Dictionary<string, string>();
        foreach (var line in r.Stdout.Split('\n'))
        {
            int eq = line.IndexOf('=');
            if (eq < 0) continue;
            var v = line[(eq + 1)..].Trim();
            if (v.Length > 0) found[line[..eq]] = v;
        }
        return names.Select(n => (n, found.GetValueOrDefault(n))).ToList();
    }

    public void SetKind(Guid hostID, HostKind kind, bool? showGPU = null, bool? alsoProcesses = null)
    {
        if (Store.Host(hostID) is not { } h) return;
        h.Kind = kind;
        if (showGPU is { } g) h.ShowGPU = g;
        if (alsoProcesses is { } a) h.SlurmAlsoProcesses = a;
        DebugLog.Log($"[{h.DisplayName}] 类型改为 {kind.Label()}");
        Store.Touch();
    }

    public void ToggleMute(Guid hostID)
    {
        if (Store.Host(hostID) is not { } h) return;
        h.Muted = !h.Muted;
        Store.Touch();
    }

    /// 在指定服务器的指定目录上只读地跑一次规则。
    public async Task<RuleTestResult> TestRule(ProgressRule rule, HostConfig host, string dir)
    {
        var r = await Run(host, AppDetectors.RuleTestScript(dir, rule), 20);
        if (r.TimedOut) return new RuleTestResult { Headline = L("连接超时", "Timed out") };
        if (r.Status == 255)
        {
            var msg = r.Stderr.Trim();
            return new RuleTestResult { Headline = L("连接失败", "Connection failed"), Notes = msg.Length == 0 ? [] : [msg.Prefix(200)] };
        }
        return AppDetectors.InterpretTest(r.Stdout, rule);
    }

    // MARK: - 曲线 / 分区

    /// 读取（增量）任务的曲线（VASP 结构优化有两张）。读不到或连接失败的那张不返回。
    public async Task<List<AppCurve>> FetchCurves(HostConfig host, AppProgress app)
    {
        if (IsDemo(host)) return DemoData.Curves(app);
        var outList = new List<AppCurve>();
        foreach (var src in AppCurves.SourcesFor(app))
        {
            var key = host.Id + "|" + src.Path;
            var cache = CurveCaches.GetValueOrDefault(key) ?? new CurveCache();
            var r = await Run(host, AppCurves.Script(src, cache.LineCount, cache.Head), 30);
            if (r.Status == 0 && AppCurves.Merge(r.Stdout, cache) is { } merged) { CurveCaches[key] = merged; cache = merged; }
            outList.AddRange(AppCurves.Curves(src, cache.Rows, cache.Extra));
        }
        return outList;
    }

    /// 查询分区资源；60 秒内重复打开直接用缓存。
    public async Task<(List<PartitionStat>? Stats, DateTime At, string? Error)> FetchPartitions(HostConfig host, bool force = false)
    {
        if (IsDemo(host)) { await Task.Delay(400); return (DemoData.Partitions(), DateTime.Now, null); }
        if (!force && PartitionCache.TryGetValue(host.Id, out var c) && (DateTime.Now - c.At).TotalSeconds < 60) return (c.Stats, c.At, null);
        var r = await Run(host, Partitions.Script(host), 25);
        if (SshCommon.Classify(r, host) is { } problem) return (null, DateTime.Now, problem.Message);
        var parsed = RemoteScript.Parse(r.Stdout);
        if (Partitions.Parse(parsed) is not { } stats)
        {
            var msg = parsed.Get("nodes")?.Lines.LastOrDefault(l => l.Length > 0) ?? L("sinfo 不可用", "sinfo unavailable");
            return (null, DateTime.Now, msg);
        }
        PartitionCache[host.Id] = (stats, DateTime.Now);
        return (stats, DateTime.Now, null);
    }
}
