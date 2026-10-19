using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using ServerIsland.Core;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;
using static ServerIsland.Desktop.Ui.Kit;

namespace ServerIsland.Desktop.Island;

/// 菜单（MenuFlyout / 右键菜单）。打开期间通知刘海不要收起。
public static class Menus
{
    public sealed record Entry(string Title, Action? Action = null, bool Checked = false, bool Header = false, bool Separator = false);

    public static Entry Sep => new("", Separator: true);

    static List<object> Build(IEnumerable<Entry> entries)
    {
        var items = new List<object>();
        foreach (var e in entries)
        {
            if (e.Separator) { items.Add(new Separator()); continue; }
            var mi = new MenuItem { Header = e.Title, IsEnabled = !e.Header };
            if (!e.Header)
            {
                mi.ToggleType = MenuItemToggleType.CheckBox;
                mi.IsChecked = e.Checked;
            }
            if (e.Action is { } a) mi.Click += (_, _) => a();
            items.Add(mi);
        }
        return items;
    }

    public static void Show(Control anchor, IEnumerable<Entry> entries, IslandState? state)
    {
        var f = new MenuFlyout { Placement = PlacementMode.BottomEdgeAlignedLeft };
        foreach (var i in Build(entries)) f.Items.Add(i);
        if (state != null)
        {
            state.MenusOpen++;
            f.Closed += (_, _) => { state.MenusOpen = Math.Max(0, state.MenusOpen - 1); };
        }
        f.ShowAt(anchor);
    }

    public static ContextMenu Context(IEnumerable<Entry> entries, IslandState? state)
    {
        var m = new ContextMenu();
        foreach (var i in Build(entries)) m.Items.Add(i);
        foreach (var i in m.Items.OfType<MenuItem>()) i.ToggleType = MenuItemToggleType.None;
        if (state != null)
        {
            m.Opened += (_, _) => state.MenusOpen++;
            m.Closed += (_, _) => state.MenusOpen = Math.Max(0, state.MenusOpen - 1);
        }
        return m;
    }
}

public sealed class CardActions
{
    public Action Login = () => { };
    public Action Refresh = () => { };
    public Action<RemoteJob> OpenJob = _ => { };
    public Action History = () => { };
    public Action Picker = () => { };
    public Action AllJobs = () => { };
    public Action Partitions = () => { };
    public Action SwitchToDirect = () => { };
    public Action TogglePause = () => { };
    public Action<int?> SetInterval = _ => { };
    public Action ToggleMute = () => { };
    public Action TerminalLogin = () => { };
    public Action Terminal = () => { };
    public int GlobalInterval = 60;
    public bool GlobalAuto = true;
    public bool LoggingIn;
    public bool CanTerminalLogin = true;
}

public static class HostCardView
{
    public static readonly int[] Presets = [15, 30, 60, 120, 300, 600];

    public static string IntervalLabel(int s)
    {
        if (s < 60) return L($"{s} 秒", $"{s} s");
        if (s % 60 == 0) return L($"{s / 60} 分钟", $"{s / 60} min");
        return L($"{s / 60} 分 {s % 60} 秒", $"{s / 60} min {s % 60} s");
    }

    public static string ShortInterval(int s) => s < 60 ? $"{s}s" : s % 60 == 0 ? $"{s / 60}m" : $"{s}s";

    public static Control Build(HostConfig host, HostSnapshot snap, CardActions a, IslandState state)
    {
        var p = IslandLayout.Parts(host, snap);
        var col = new StackPanel { Orientation = Orientation.Vertical };
        col.Children.Add(Header(host, snap, a, state).Hgt(IslandLayout.CardHeader));
        Control Gap() => new Control { Height = IslandLayout.SectionGap };

        if (p.Paused)
        {
            col.Children.Add(Gap());
            var text = snap.LastUpdate is { } lu
                ? LiveT(() => L($"自动刷新已暂停 · 数据停在 {Format.Relative(lu)}", $"Auto refresh paused · data from {Format.Relative(lu)}"), 10.5, color: Hue.Amber.WithAlpha(0.9))
                : T(L("自动刷新已暂停 · 不会连接这台服务器", "Auto refresh paused · not contacting this server"), 10.5, color: Hue.Amber.WithAlpha(0.9));
            col.Children.Add(Row(6,
                new Icon("pause", 10, Hue.Amber.WithAlpha(0.9).B()),
                Fill(text),
                LinkButton("refresh", L("刷新一次", "Refresh Once"), Hue.Cyan, a.Refresh),
                LinkButton("play", L("恢复", "Resume"), Hue.Mint, a.TogglePause)).Hgt(IslandLayout.EmptyRow));
        }
        if (p.Problem) { col.Children.Add(Gap()); col.Children.Add(ProblemRow(host, snap, a).Hgt(IslandLayout.ProblemRow)); }
        if (p.Connecting)
        {
            col.Children.Add(Gap());
            col.Children.Add(H(6, new MiniSpinner(9), T(L("正在连接…", "Connecting…"), 11, color: Hue.Tertiary)).Hgt(IslandLayout.EmptyRow));
        }
        if (p.Metrics) { col.Children.Add(Gap()); col.Children.Add(Metrics(host, snap).Hgt(IslandLayout.MetricsRow).Op(host.Paused ? 0.45 : 1)); }
        if (p.Warnings > 0)
        {
            col.Children.Add(new Control { Height = 6 });
            foreach (var w in snap.Warnings)
            {
                bool missing = IsMissingSqueue(w, host);
                var row = Row(5,
                    new Icon("warningFill", 9, Hue.Amber.WithAlpha(0.85).B()),
                    Fill(T(missing ? L("这台机器上没有 squeue，可能不是 Slurm 集群", "squeue not found — check Environment settings") : w, 10, color: Hue.Amber.WithAlpha(0.85)).Middle()),
                    missing
                        ? new Clickable(a.SwitchToDirect)
                        {
                            CornerRadius = new CornerRadius(100), Padding = new Thickness(7, 1.5),
                            Normal = Hue.Amber.WithAlpha(0.2), Hover = Hue.Amber.WithAlpha(0.3),
                            Child = T(L("改为直连服务器", "Switch to Direct"), 9.5, FontWeight.Bold, Hue.Amber),
                        }.Tip(L("如果是集群但 squeue 不在 PATH 里，请改在 设置 → 环境 → 连接后先执行 里加 module load slurm",
                                "If Slurm is installed but not on PATH, add e.g. module load slurm under Settings → Environment → Run First"))
                        : null);
                col.Children.Add(row.Hgt(IslandLayout.WarningRow).Tip(w + L("\n可以在 设置 → 高级 里调整", "\nAdjust under Settings → Advanced")));
            }
        }
        if (p.JobRows > 0)
        {
            col.Children.Add(Gap());
            var jobsCol = new StackPanel { Spacing = IslandLayout.JobGap };
            foreach (var job in snap.Jobs.Take(IslandLayout.MaxJobs))
                jobsCol.Children.Add(JobRowButton(job, host.Kind, host.Paused ? null : snap.LastUpdate, () => a.OpenJob(job), state)
                    .Hgt(IslandLayout.JobRow).Op(host.Paused ? 0.45 : 1));
            col.Children.Add(jobsCol);
        }
        if (p.More > 0)
        {
            col.Children.Add(new Control { Height = 4 });
            var more = new Clickable(a.AllJobs)
            {
                Child = H(4, T(L($"还有 {p.More} 个任务，查看全部", $"{p.More} more — show all"), 10, FontWeight.Medium, Hue.Cyan.WithAlpha(0.9)),
                          new Icon("chevronRight", 9, Hue.Cyan.WithAlpha(0.9).B(), 3)),
                HorizontalAlignment = HorizontalAlignment.Left,
                Margin = new Thickness(32, 0, 0, 0),
            };
            col.Children.Add(more.Hgt(IslandLayout.MoreRow));
        }
        if (p.EmptyJobs)
        {
            col.Children.Add(Gap());
            col.Children.Add(H(6, new Icon("moon", 10, Hue.Tertiary.B()),
                T(host.Kind.IsScheduler() ? L("队列里没有你的作业", "No jobs in the queue") : L("空闲中 · 没有在跑的任务", "Idle · nothing running"), 11, color: Hue.Tertiary))
                .Hgt(IslandLayout.EmptyRow));
        }

        return new Border
        {
            Padding = new Thickness(IslandLayout.CardPad),
            Height = IslandLayout.CardHeight(p),
            CornerRadius = new CornerRadius(16),
            Background = Hue.Vertical(Hue.W(0.075), Hue.W(0.035)),
            BorderBrush = Hue.Vertical(Hue.W(0.14), Hue.W(0.03)),
            BorderThickness = new Thickness(0.6),
            Child = col,
            ClipToBounds = true,
        };
    }

    static Control LinkButton(string icon, string title, Color c, Action action) => new Clickable(action)
    {
        Child = H(3, new Icon(icon, 9.5, c.B(), 2.6), T(title, 10, FontWeight.SemiBold, c)),
        Padding = new Thickness(2, 0),
    };

    /// squeue / qstat 不存在（command not found / 未找到命令 / 退出码 127）。注意：用来匹配服务器输出，不能翻译。
    public static bool IsMissingSqueue(string w, HostConfig host)
    {
        if (!(host.Kind == HostKind.Slurm && w.StartsWith("squeue")) && !(host.Kind == HostKind.Pbs && w.StartsWith("qstat"))) return false;
        var l = w.ToLowerInvariant();
        return l.Contains("not found") || w.Contains("未找到") || l.Contains("no such file") || w.Contains("127");
    }

    static Control Header(HostConfig host, HostSnapshot snap, CardActions a, IslandState state)
    {
        var left = new ShrinkRow(7, 1,
            StatusDot(host.Paused ? Hue.Tertiary : Hue.For(snap.Health), 6.5),
            T(host.DisplayName, 13, FontWeight.SemiBold),
            KindBadge(host.Kind),
            snap.RunningCount + snap.PendingCount > 0 ? JobCountChips(snap.RunningCount, snap.PendingCount, host.Paused) : null);

        var buttons = H(0,
            host.Kind == HostKind.Direct
                ? SmallIconButton("eye", L("从高负载进程中挑选要监听的进程", "Pick a busy process to watch"), a.Picker)
                : host.Kind == HostKind.Slurm
                    ? SmallIconButton("grid", L("分区空闲资源（按需查询 sinfo）", "Free partition resources (sinfo, on demand)"), a.Partitions, size: 10)
                    : null,
            SmallIconButton("terminal", L("在终端中打开这台服务器（ssh 登录）", "Open this server in a terminal (ssh)"), a.Terminal),
            SmallIconButton("history", L("历史记录：结束的任务、目录", "History: finished jobs and their folders"), a.History),
            IntervalMenu(host, a, state),
            SmallIconButton(host.Paused ? "play" : "pause",
                host.Paused ? L("恢复自动刷新", "Resume auto refresh") : L("暂停自动刷新（知道这台机器没有任务时用；仍可手动刷新）", "Pause auto refresh (manual refresh still works)"),
                a.TogglePause, host.Paused ? Hue.Amber : Hue.Tertiary, 9.5),
            SmallIconButton(host.Muted ? "bellSlash" : "bell",
                host.Muted ? L("取消静音", "Unmute") : L("静音这台服务器（不弹提示、不发通知、不响铃）", "Mute this server (no pop-ups, notifications or sounds)"),
                a.ToggleMute, host.Muted ? Hue.Amber : Hue.Tertiary));

        var right = H(7, buttons);
        if (snap.IsRefreshing) right.Children.Add(new MiniSpinner(10));
        if (snap.LastUpdate is { } t) right.Children.Add(LiveT(() => Format.Relative(t), 10, color: Hue.Tertiary));
        if (snap.Latency is { } lat) right.Children.Add(T($"{(int)(lat * 1000)}ms", 10, color: Hue.Tertiary).Tip(L("本次查询耗时（含 SSH 往返）", "Query time incl. SSH round trip")));
        return Row(6, Fill(left), right);
    }

    static Control IntervalMenu(HostConfig host, CardActions a, IslandState state)
    {
        string label;
        if (host.Paused) label = L("暂停", "paused");
        else if (host.Interval == null && !a.GlobalAuto) label = L("手动", "manual");
        else label = ShortInterval(host.Interval ?? a.GlobalInterval);
        Clickable? b = null;
        b = new Clickable(() =>
        {
            var entries = new List<Menus.Entry>
            {
                new(L("跟随全局", "Global") + "（" + (a.GlobalAuto ? IntervalLabel(a.GlobalInterval) : L("仅手动", "manual")) + "）", () => a.SetInterval(null), host.Interval == null),
                Menus.Sep,
            };
            entries.AddRange(Presets.Select(s => new Menus.Entry(L($"每 {IntervalLabel(s)}", $"Every {IntervalLabel(s)}"), () => a.SetInterval(s), host.Interval == s)));
            Menus.Show(b!, entries, state);
        })
        {
            Height = 18,
            Padding = new Thickness(5, 0),
            CornerRadius = new CornerRadius(100),
            BorderBrush = Hue.W(0.12).B(),
            BorderThickness = new Thickness(1),
            Child = T(label, 9.5, FontWeight.SemiBold, host.Paused ? Hue.Tertiary.WithAlpha(0.6) : Hue.Tertiary),
            Margin = new Thickness(2, 0),
            VerticalAlignment = VerticalAlignment.Center,
        };
        return b.Tip(L("这台服务器的轮询间隔", "Refresh interval for this server"));
    }

    static Control Metrics(HostConfig host, HostSnapshot snap)
    {
        var m = snap.Metrics;
        var row = H(16);
        if (host.ShowCPU && m.CpuPercent is { } cpu)
        {
            var help = string.Join(" · ", new[] { m.Cores is { } c ? L($"{c} 核", $"{c} cores") : null, m.Load1 is { } l ? L($"负载 {l:0.00}", $"load {l:0.00}") : null }.Where(s => s != null));
            row.Children.Add(MetricChip("CPU", cpu / 100, $"{(int)Math.Round(cpu)}%", help));
        }
        if (host.ShowMemory && m.MemoryFraction is { } f)
        {
            var used = Format.Bytes(m.MemoryUsed ?? 0);
            row.Children.Add(MetricChip(L("内存", "MEM"), f, $"{used[..^1]}/{Format.Bytes(m.MemoryTotal ?? 0)}", L($"已用 {Format.Percent(f)}", $"{Format.Percent(f)} used")));
        }
        if (host.ShowGPU && snap.Gpus.Count > 0)
        {
            if (snap.Gpus.Count <= 2) foreach (var g in snap.Gpus) row.Children.Add(GPUDetailChip(g, snap.Gpus.Count > 1));
            else row.Children.Add(GPUCells(snap.Gpus));
        }
        if (host.ShowDisk && snap.Disks.OrderByDescending(d => d.Fraction).FirstOrDefault() is { } d && d.Fraction >= 0.8)
            row.Children.Add(DiskChip(d, snap.Disks));
        return row;
    }

    static Control ProblemRow(HostConfig host, HostSnapshot snap, CardActions a)
    {
        bool isLogin = snap.Health.Kind == HealthKind.NeedsLogin;
        var msg = snap.Health.Message;
        var items = new List<object?>
        {
            new Icon(isLogin ? "key" : "wifiAlert", 12, (isLogin ? Hue.Amber : Hue.Coral).B(), 2.4),
            Fill(T(msg, 11.5, color: Hue.Secondary).Tip(msg)),
        };
        if (isLogin)
        {
            if (a.LoggingIn)
            {
                items.Add(new MiniSpinner(10));
                items.Add(T(L("等待输入…", "Waiting…"), 10.5, color: Hue.Amber));
            }
            else
            {
                items.Add(PillButton(L("登录…", "Log In…"), Hue.Amber, a.Login)
                    .Tip(L($"弹出对话框输入密码 / 动态口令；连接会在后台保持（{host.KeepAlive.Label()}）", $"Enter your password / OTP in a dialog; the connection is kept for {host.KeepAlive.Label()}")));
                if (a.CanTerminalLogin) items.Add(SmallIconButton("terminal", L("改用终端登录", "Log in via Terminal"), a.TerminalLogin));
            }
        }
        items.Add(PillButton(L("重试", "Retry"), Hue.Secondary, a.Refresh));
        return Row(8, [.. items]);
    }

    // MARK: - 任务行

    public static Control JobRowButton(RemoteJob job, HostKind kind, DateTime? sampledAt, Action action, IslandState? state)
    {
        var chevron = new Icon("chevronRight", 9, Hue.Tertiary.B(), 3) { IsVisible = false, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 0, -4, 0) };
        var grid = new Grid();
        grid.Children.Add(JobRow(job, kind, sampledAt));
        grid.Children.Add(chevron);
        var b = new Clickable(action)
        {
            CornerRadius = new CornerRadius(9),
            Padding = new Thickness(6, 0),
            Margin = new Thickness(-6, 0),
            Normal = Colors.Transparent,
            Hover = Hue.W(0.07),
            Child = grid,
        };
        b.HoverChanged = h => chevron.IsVisible = h;
        var entries = new List<Menus.Entry> { new(L("查看详情和日志", "Details & Log"), action) };
        if (job.Source != JobSource.ProgressFile)
            entries.Add(new(job.Source == JobSource.Process ? L("复制 PID", "Copy PID") : L("复制作业号", "Copy Job ID"), () => _ = Ui.Clipboard.SetText(b, job.Id)));
        entries.Add(new(L("复制名称", "Copy Name"), () => _ = Ui.Clipboard.SetText(b, job.Name)));
        if (job.Source == JobSource.Process && job.Detail.Length > 0)
            entries.Add(new(L("复制完整命令", "Copy Full Command"), () => _ = Ui.Clipboard.SetText(b, job.Detail)));
        b.ContextMenu = Menus.Context(entries, state);
        return b.Tip(L("点击查看详情和日志 · 右键复制", "Click for details & log · right-click to copy"));
    }

    /// 运行中的任务在两次采样之间本地继续计时，看起来是"活"的。
    static double? LiveElapsed(RemoteJob job, DateTime? sampledAt)
    {
        if (job.Elapsed is not { } e) return null;
        if (job.State == JobState.Running && sampledAt is { } t) return e + Math.Max(0, (DateTime.Now - t).TotalSeconds);
        return e;
    }

    static double? LiveFraction(RemoteJob job, DateTime? sampledAt)
    {
        if (job.Progress is { } p) return Math.Clamp(p, 0, 1);
        if (LiveElapsed(job, sampledAt) is { } e && job.Limit is { } l && l > 0) return Math.Min(e / l, 1);
        return null;
    }

    public static Control JobRow(RemoteJob job, HostKind kind, DateTime? sampledAt)
    {
        var line1 = new ShrinkRow(6, 0, T(job.Name, 12, FontWeight.Medium).Middle().Tip(job.Detail.Length == 0 ? job.Name : job.Detail));
        if (job.Watched) line1.Children.Add(new Icon("eyeFill", 10, Hue.Mint.B()).Tip(L("手动监听的进程", "Watched process")));
        if (job.Array != null) line1.Children.Add(T(L($"数组 #{job.Id}", $"array #{job.Id}"), 9.5, FontWeight.SemiBold, Hue.Violet, mono: true));
        else if (job.Source != JobSource.ProgressFile) line1.Children.Add(T(job.Source == JobSource.Slurm ? $"#{job.Id}" : $"pid {job.Id}", 9.5, color: Hue.Tertiary, mono: true));
        var right = LiveT(() => RightText(job, sampledAt), 10.5, FontWeight.Medium, job.HasRealProgress ? Hue.Mint : Hue.Secondary);
        var top = Row(6, Fill(line1), right);

        Control bottom;
        if (job.Array is { } a)
        {
            bottom = Row(10, Fill(new ArrayBar { Array = a, BarHeight = 4 }.Tip(ArrayBar.Legend(a))), ArrayStatusText(a).W(210).Tip(ArrayBar.Legend(a)));
        }
        else if (job.State == JobState.Pending)
        {
            var r = PendingReason.Explain(job.Reason);
            bool act = r?.NeedsAction == true;
            var c = act ? Hue.Coral.WithAlpha(0.9) : Hue.Amber.WithAlpha(0.8);
            bottom = H(4, act ? new Icon("warningFill", 9, c.B()) : null, T(PendingText(job, r), 10, act ? FontWeight.SemiBold : FontWeight.Normal, c)).Tip(r?.Long ?? job.Detail);
        }
        else
        {
            var bar = new SlimBar
            {
                Fraction = LiveFraction(job, sampledAt),
                Fill = job.HasRealProgress ? Hue.Progress : Hue.TimeProgress,
                BarHeight = 4,
            };
            LiveScope.Register(() => { var f = LiveFraction(job, sampledAt); if (f != bar.Fraction) { bar.Fraction = f; bar.InvalidateVisual(); } });
            var detail = T(DetailText(job), 10, color: Hue.Tertiary);
            detail.TextAlignment = TextAlignment.Right;
            bottom = Row(10, Fill(bar), detail.W(210));
        }
        return Row(10, Icon(job), Fill(V(6, top, bottom).VA(VerticalAlignment.Center)));
    }

    static Control Icon(RemoteJob job)
    {
        var c = Hue.For(job.State);
        var name = job.State switch
        {
            JobState.Pending => "hourglass",
            JobState.Completing => "arrowDown",
            JobState.Completed => "check",
            JobState.Failed or JobState.Timeout => "xmark",
            JobState.Cancelled => "minus",
            JobState.Other => "question",
            _ => job.Array != null ? "stack" : job.App != null ? "atom" : job.Source switch
            {
                JobSource.Slurm => "bolt",
                JobSource.Process => "terminal",
                _ => "chart",
            },
        };
        return new Border
        {
            Width = 22, Height = 22,
            CornerRadius = new CornerRadius(11),
            Background = c.WithAlpha(0.15).B(),
            Child = new Icon(name, 11, c.B(), 2.8) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    static string PendingText(RemoteJob job, PendingReason? r)
    {
        if (r == null) return job.Detail.Length == 0 ? L("等待调度", "Waiting") : job.Detail;
        // detail 形如 "(Priority) · a100"：保留分区
        var last = job.Detail.Split(" · ").Last();
        var partition = last.StartsWith('(') ? null : last;
        return string.Join(" · ", new[] { r.Short, partition }.Where(s => !string.IsNullOrEmpty(s)));
    }

    static string RightText(RemoteJob job, DateTime? sampledAt)
    {
        if (job.Array is { } a) return L($"完成 {a.Done + a.Failed}/{Math.Max(a.Total, 1)}", $"{a.Done + a.Failed}/{Math.Max(a.Total, 1)} done");
        if (job.State == JobState.Pending) return job.Limit is { } l ? L("上限 ", "limit ") + Format.Duration(l) : job.State.Label();
        var live = LiveElapsed(job, sampledAt);
        if (job.Progress is { } p)
        {
            var s = Format.Percent(p);
            if (job.Eta is { } eta) s += L(" · 约剩 ", " · ~") + Format.ShortDuration(eta);
            else if (job.App != null) { }   // 计算软件：还没有两次采样，暂时不估算
            else if (live is { } e && p > 0.01 && p < 1) s += L(" · 约剩 ", " · ~") + Format.ShortDuration(e * (1 - p) / p);
            return s;
        }
        if (live is { } el) return job.Limit is { } lim ? Format.Duration(el) + " / " + Format.Duration(lim) : Format.Duration(el);
        return job.State.Label();
    }

    static string DetailText(RemoteJob job)
    {
        if (!string.IsNullOrEmpty(job.Message)) return job.Message;
        if (job.Source == JobSource.Process)
        {
            var parts = new List<string>();
            if (job.GpuMemoryMB is { } g) parts.Add(L("显存 ", "VRAM ") + Format.Bytes(g * 1_048_576));
            if (job.CpuPercent is { } c) parts.Add($"CPU {(int)c}%");
            if (job.MemoryBytes is { } m) parts.Add(L("内存 ", "MEM ") + Format.Bytes(m));
            return string.Join(" · ", parts);
        }
        return job.Detail;
    }

    /// 数组状态文字，颜色和 ArrayBar 的分段一致：运行蓝、排队灰、失败红。
    public static Control ArrayStatusText(ArrayInfo a)
    {
        var parts = new List<(string, Color)>();
        if (a.Running.Count > 0) parts.Add((L($"运行 {a.Running.Count}", $"{a.Running.Count} running"), Hue.Cyan));
        if (a.Pending > 0) parts.Add((L($"排队 {a.Pending}", $"{a.Pending} pending"), Hue.Secondary));
        if (a.Failed > 0) parts.Add((L($"失败 {a.Failed}", $"{a.Failed} failed"), Hue.Coral));
        var tb = new TextBlock { FontSize = 10, FontFamily = Hue.Sans, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
        for (int i = 0; i < parts.Count; i++)
        {
            if (i > 0) tb.Inlines!.Add(new Avalonia.Controls.Documents.Run(" · ") { Foreground = Hue.Tertiary.WithAlpha(0.6).B() });
            tb.Inlines!.Add(new Avalonia.Controls.Documents.Run(parts[i].Item1) { Foreground = parts[i].Item2.B() });
        }
        return tb;
    }

    // MARK: - 合并的空闲机器

    public static Control IdleHostsRow(List<(HostConfig Host, HostSnapshot Snap)> hosts, bool expanded, Action action)
    {
        var names = H(10);
        foreach (var (h, s) in hosts)
            names.Children.Add(H(4, h.Paused ? new Icon("pause", 7, Hue.Tertiary.B()) : StatusDot(Hue.For(s.Health), 5),
                                 T(h.DisplayName, 11, color: Hue.Tertiary)).Tip(Summary(h, s)));
        var toggle = H(3, T(expanded ? L("收起", "Hide") : L("展开", "Show"), 10, FontWeight.Medium, Hue.Cyan.WithAlpha(0.85)),
                       new Icon(expanded ? "chevronUp" : "chevronDown", 8, Hue.Cyan.WithAlpha(0.85).B(), 3));
        var content = Row(8, new Icon("moon", 10.5, Hue.Tertiary.B()),
            T(L($"{hosts.Count} 台空闲", $"{hosts.Count} idle"), 11, FontWeight.SemiBold, Hue.Secondary),
            Fill(new Border { ClipToBounds = true, Child = names }), toggle);
        var b = new Clickable(action)
        {
            CornerRadius = new CornerRadius(14),
            Padding = new Thickness(IslandLayout.CardPad, 0),
            Normal = Hue.W(0.04),
            Hover = Hue.W(0.07),
            BorderBrush = Hue.W(0.08).B(),
            BorderThickness = new Thickness(0.6),
            Child = content,
        };
        return b.Tip(L("没有任务的机器合并在这里；可以在 设置 → 通用 里关闭", "Servers with no jobs are grouped here; turn off in Settings → General"));
    }

    static string Summary(HostConfig host, HostSnapshot snap)
    {
        if (host.Paused) return L($"{host.DisplayName} · 自动刷新已暂停", $"{host.DisplayName} · auto refresh paused");
        var m = snap.Metrics;
        var parts = new List<string> { host.DisplayName };
        if (m.CpuPercent is { } c) parts.Add($"CPU {(int)Math.Round(c)}%");
        if (m.MemoryFraction is { } f) parts.Add(L("内存 ", "MEM ") + Format.Percent(f));
        if (snap.Gpus.Count > 0) parts.Add($"GPU {snap.Gpus.Count(g => g.Utilization >= 10)}/{snap.Gpus.Count}" + L(" 在用", " busy"));
        return string.Join(" · ", parts);
    }
}
