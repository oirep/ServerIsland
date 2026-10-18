using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ServerIsland.Core;
using ServerIsland.Desktop.Platform;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;
using static ServerIsland.Desktop.Ui.Kit;

namespace ServerIsland.Desktop.Island;

/// 展开面板里的二级页面（与 Swift 版 IslandPages.swift 对应）。每个页面固定高 IslandLayout.PageHeight。
public sealed class IslandPages(MonitorEngine engine, IslandState st)
{
    void Back() => st.Page = IslandPage.List;

    static Control PageHeader(string title, string subtitle, Action onBack, Control? trailing)
    {
        var titles = V(1, T(title, 13.5, FontWeight.SemiBold).Middle(), T(subtitle, 10.5, color: Hue.Tertiary).Middle());
        return Row(10, IconButton("chevronLeft", L("返回", "Back"), onBack), Fill(titles), trailing).Hgt(30);
    }

    /// 宽度 / 高度固定的页面骨架：标题行 + 若干行（其中 star 行占满剩余高度）。
    static Grid Rows(string spec, params Control[] children)
    {
        var g = new Grid { RowDefinitions = new RowDefinitions(spec), Height = IslandLayout.PageHeight };
        int r = 0;
        foreach (var c in children)
        {
            Grid.SetRow(c, r);
            g.Children.Add(c);
            r += 2;
        }
        return g;
    }

    static ScrollViewer Scroll(Control content, bool indicators = false) => new()
    {
        Content = content,
        VerticalScrollBarVisibility = indicators ? ScrollBarVisibility.Auto : ScrollBarVisibility.Hidden,
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
    };

    static Control Centered(string text, double top = 40) =>
        T(text, 11.5, color: Hue.Tertiary).HA(HorizontalAlignment.Center).Margin(0, top, 0, 0);

    static Control Loading(double top = 40) => new MiniSpinner(14).HA(HorizontalAlignment.Center).Margin(0, top, 0, 0);

    // MARK: - 任务详情

    public Control JobDetail(HostConfig host, RemoteJob job, DateTime? sampledAt, bool stillListed, Action<RemoteJob> openElement)
    {
        var s = st.StateFor(() => new JobDetailState());
        if (!s.Started && job.Array == null && !PreviewMode)
        {
            s.Started = true;
            _ = DetailLoop(host, job, s);
        }
        string kindText = job.Array != null ? L($"数组作业 #{job.Id}", $"Job array #{job.Id}")
            : job.Source == JobSource.Slurm ? L($"作业 #{job.Id}", $"Job #{job.Id}")
            : job.Source == JobSource.Process ? $"PID {job.Id}" : L("进度文件", "Progress file");
        var trailing = H(6);
        if (job.Source != JobSource.ProgressFile)
            trailing.Children.Add(CopyButton(job.Id, job.Source == JobSource.Process ? L("复制 PID", "Copy PID") : L("复制作业号", "Copy job ID"),
                                             job.Source == JobSource.Process ? "PID" : L("作业号", "Job ID")));
        var sc = Hue.For(job.State);
        trailing.Children.Add(Capsule(T(job.State.Label(), 10, FontWeight.Bold, sc), sc.WithAlpha(0.15), 7, 2.5));
        trailing.Children.Add(IconButton("refresh", L("刷新详情", "Refresh details"), () => _ = LoadDetail(host, job, s), spinning: s.Loading));
        var header = PageHeader(job.Name, $"{host.DisplayName} · {kindText}" + (stillListed ? "" : L(" · 已不在列表中", " · no longer listed")), Back, trailing);

        if (job.Array is { } a)
            return Rows("Auto,10,*,10,30", header, ArrayOverview(job, a, openElement), DangerZone(host, job, sampledAt, stillListed, s));
        var parts = new List<Control> { header, Fields(job, s) };
        var spec = "Auto,10,Auto,10";
        if (s.Curves.Count > 0)
        {
            var charts = new Grid { ColumnDefinitions = new ColumnDefinitions(string.Join(",8,", s.Curves.Select(_ => "*"))) };
            for (int i = 0; i < s.Curves.Count; i++)
            {
                var c = CurveChart.Build(s.Curves[i], compact: s.Curves.Count > 1);
                Grid.SetColumn(c, i * 2);
                charts.Children.Add(c);
            }
            parts.Add(charts.Hgt(104));
            spec += ",Auto,10";
        }
        parts.Add(LogBox(host, s));
        parts.Add(DangerZone(host, job, sampledAt, stillListed, s));
        spec += ",*,10,30";
        return Rows(spec, [.. parts]);
    }

    public static bool PreviewMode => Preview.PreviewRenderer.Active;

    async Task DetailLoop(HostConfig host, RemoteJob job, JobDetailState s)
    {
        // 打开期间每 4 秒刷新一次日志末尾；曲线（增量）每 20 秒一次。离开页面自动停止。
        int tick = 0;
        while (!s.Disposed)
        {
            await LoadDetail(host, job, s);
            if (tick % 5 == 0 && job.App is { } app && AppCurves.SourcesFor(app).Count > 0)
            {
                var c = await engine.FetchCurves(host, app);
                if (!s.Disposed) { s.Curves = c; st.RequestRebuild(); }
            }
            tick++;
            try { await Task.Delay(4000, s.Token); } catch { return; }
        }
    }

    async Task LoadDetail(HostConfig host, RemoteJob job, JobDetailState s)
    {
        s.Loading = true;
        st.RequestRebuild();
        var d = await engine.FetchDetail(host, job);
        if (s.Disposed) return;
        s.Detail = d;
        s.Loading = false;
        st.RequestRebuild();
    }

    /// 计算软件识别到的信息，排在服务器字段前面。
    static List<(string, string)> AppFields(RemoteJob job)
    {
        if (job.State == JobState.Pending && PendingReason.Explain(job.Reason) is { } r)
            return [(L("排队原因", "Pending reason"), r.Short + "：" + r.Long.Replace("\n", " "))];
        if (job.App is not { } a) return [];
        var f = new List<(string, string)> { (L("软件", "Software"), a.Title) };
        if (a.Current is { } c)
        {
            var p = AppProgress.Compact(c) + (a.Total is { } t ? " / " + AppProgress.Compact(t) : "") + " " + a.Unit;
            if (a.Fraction is { } fr) p += $"（{Format.Percent(fr)}）";
            if (!a.HasTarget)
            {
                p += a.Kind switch
                {
                    AppKind.Gpumd => L("，run.in 无 run 步数", ", no run steps in run.in"),
                    AppKind.Nep or AppKind.Gnep => L("，未设目标按默认值", ", default target"),
                    AppKind.Vasp => a.Vasp == VaspMode.Relax ? L("（收敛前不知道总步数）", " (total unknown until converged)") : "",
                    _ => "",
                };
            }
            f.Add((L("进度", "Progress"), p));
        }
        if (a.Rate is { } rate) f.Add((L("速度", "Speed"), AppProgress.Compact(rate) + L($" {a.Unit}/秒", $" {a.Unit}/s")));
        if (a.Eta is { } eta) f.Add((L("预计剩余", "ETA"), Format.Duration(eta)));
        if (a.UpdatedAt is { } u) f.Add((L("输出更新", "Last output"), Format.Relative(u)));
        if (a.EndMarker is { } m) f.Add((L("结束标记", "End marker"), m ? L("已正常结束", "finished normally") : L("还没有出现", "not yet")));
        if (a.Neigh is { } n)
            f.Add((L("近邻", "Neighbors"), L($"径向 {n.RadialActual}/{n.RadialMax} · 角向 {n.AngularActual}/{n.AngularMax}",
                                              $"radial {n.RadialActual}/{n.RadialMax} · angular {n.AngularActual}/{n.AngularMax}")));
        if (a.Losses.Count > 0)
            f.Add(("Loss", string.Join(" · ", a.Losses.Where(l => l.Label is not ("L1" or "L2")).Select(l => $"{l.Label} {AppProgress.Sci(l.V)}"))));
        f.Add((L("工作目录", "Directory"), a.Dir));
        return f;
    }

    Control Fields(RemoteJob job, JobDetailState s)
    {
        var all = AppFields(job);
        foreach (var kv in s.Detail?.Fields ?? []) if (!all.Any(x => x.Item1 == kv.Key)) all.Add((kv.Key, kv.Value));
        var longKeys = new HashSet<string> { L("命令", "Command"), L("工作目录", "Directory"), L("资源", "Resources"), L("节点", "Nodes"), "Loss",
                                             L("近邻", "Neighbors"), L("进度", "Progress"), L("排队原因", "Pending reason") };
        var shortF = all.Where(x => !longKeys.Contains(x.Item1)).Take(job.App == null ? 8 : 10).ToList();
        var wide = all.Where(x => longKeys.Contains(x.Item1)).ToList();

        var col = V(5);
        if (s.Detail?.Error is { } err)
            col.Children.Add(H(6, new Icon("warningFill", 11, Hue.Amber.B()), T(err, 11, color: Hue.Amber)));
        else if (s.Detail == null)
            col.Children.Add(H(6, new MiniSpinner(10), T(L("正在从服务器读取…", "Loading from server…"), 11, color: Hue.Tertiary)));
        if (shortF.Count > 0)
        {
            var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("*,14,*"), RowSpacing = 5 };
            int rows = (shortF.Count + 1) / 2;
            for (int i = 0; i < rows; i++) grid.RowDefinitions.Add(new RowDefinition(GridLength.Auto));
            for (int i = 0; i < shortF.Count; i++)
            {
                var row = FieldRow(shortF[i].Item1, shortF[i].Item2);
                Grid.SetRow(row, i / 2);
                Grid.SetColumn(row, i % 2 == 0 ? 0 : 2);
                grid.Children.Add(row);
            }
            col.Children.Add(grid);
        }
        foreach (var (k, v) in wide) col.Children.Add(FieldRow(k, v));
        // 字段很多时卡片内部滚动，给下面的日志留出空间。
        var sv = new ScrollViewer { Content = col, MaxHeight = s.Curves.Count > 0 ? 138 : 196, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        return RoundedCard(sv, 12, Hue.Card, 10);
    }

    static Control FieldRow(string k, string v)
    {
        var value = new SelectableTextBlock
        {
            Text = v, FontSize = 10.5, FontFamily = Hue.Mono, Foreground = Hue.Secondary.B(),
            TextTrimming = TextTrimming.PrefixCharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center,
        }.Tip(v);
        bool copy = k == L("工作目录", "Directory") || k == L("命令", "Command") || k == L("节点", "Nodes");
        return Row(8, T(k, 10, FontWeight.Medium, Hue.Tertiary).W(58), Fill(value), copy ? CopyButton(v, L("复制", "Copy ") + k) : null);
    }

    Control LogBox(HostConfig host, JobDetailState s)
    {
        var log = s.ShowStderr ? s.Detail?.Stderr : s.Detail?.Stdout;
        var header = H(6, T(L("日志末尾", "Log tail"), 10.5, FontWeight.SemiBold, Hue.Secondary));
        if (s.Detail?.Stderr != null)
        {
            header.Children.Add(Segment("stdout", !s.ShowStderr, () => { s.ShowStderr = false; st.RequestRebuild(); }));
            header.Children.Add(Segment("stderr", s.ShowStderr, () => { s.ShowStderr = true; st.RequestRebuild(); }));
        }
        var right = H(6);
        if (log?.Path is { } path)
        {
            header.Children.Add(T(path, 9.5, color: Hue.Tertiary, mono: true).Head().Tip(path).W(Math.Min(220, path.Length * 6.2)));
            header.Children.Add(CopyButton(path, L("复制日志路径", "Copy log path")));
            header.Children.Add(CopyButton($"ssh {host.Alias} " + RemoteScript.ShellQuote("tail -f " + RemoteScript.ShellQuote(path)),
                L("复制一条可以在本机终端里实时查看日志的命令", "Copy a command to follow this log from your terminal"), "tail -f"));
        }
        if (s.Detail?.Fields.FirstOrDefault(f => f.Key == L("工作目录", "Directory")).Value is { Length: > 0 } dir)
            right.Children.Add(SmallIconButton("terminal", L("在终端中打开（ssh 到工作目录）", "Open in Terminal (ssh to the directory)"),
                () => Shell.OpenShellInTerminal(host, dir)));

        var lines = new StackPanel { Spacing = 1, Margin = new Thickness(8) };
        if (log is { Lines.Count: > 0 })
        {
            foreach (var line in log.Lines)
                lines.Children.Add(new SelectableTextBlock
                {
                    Text = line.Length == 0 ? " " : line, FontSize = 10, FontFamily = Hue.Mono, Foreground = Tint(line).B(),
                    TextWrapping = TextWrapping.NoWrap, TextTrimming = TextTrimming.CharacterEllipsis,
                });
        }
        else
        {
            lines.Children.Add(T(log?.Note ?? (s.Detail == null ? "" : L("（日志为空）", "(empty log)")), 10.5, color: Hue.Tertiary));
        }
        var scroll = Scroll(lines, indicators: true);
        // 行数变了就滚到最底；没变时保留用户的滚动位置。
        int count = log?.Lines.Count ?? 0;
        bool jump = count != s.LastLogCount;
        var restore = s.LogOffset;
        s.LastLogCount = count;
        scroll.ScrollChanged += (_, _) => s.LogOffset = scroll.Offset;
        Dispatcher.UIThread.Post(() => { if (jump) scroll.ScrollToEnd(); else scroll.Offset = restore; }, DispatcherPriority.Loaded);
        var box = new Border
        {
            Background = Hue.W(0.04).B(),
            BorderBrush = Hue.Hairline.B(),
            BorderThickness = new Thickness(0.5),
            CornerRadius = new CornerRadius(10),
            Child = scroll,
            ClipToBounds = true,
        };
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,6,*") };
        g.Children.Add(Row(6, Fill(new Border { ClipToBounds = true, Child = header }), right));
        Grid.SetRow(box, 2);
        g.Children.Add(box);
        return g;
    }

    static Control Segment(string title, bool on, Action action) => new Clickable(action)
    {
        CornerRadius = new CornerRadius(100),
        Padding = new Thickness(6, 2),
        Normal = Hue.W(on ? 0.14 : 0),
        Hover = Hue.W(on ? 0.18 : 0.08),
        Child = T(title, 9.5, FontWeight.SemiBold, on ? Hue.Text : Hue.Tertiary, mono: true),
    };

    /// 报错行标红，便于一眼看到。
    public static Color Tint(string line)
    {
        var l = line.ToLowerInvariant();
        if (l.Contains("error") || l.Contains("traceback") || l.Contains("exception") || l.Contains("out of memory") || l.Contains("killed"))
            return Hue.Coral.WithAlpha(0.9);
        if (l.Contains("warn")) return Hue.Amber.WithAlpha(0.85);
        return Hue.Secondary;
    }

    // MARK: 取消

    Control DangerZone(HostConfig host, RemoteJob job, DateTime? sampledAt, bool stillListed, JobDetailState s)
    {
        bool cancellable = job.Source != JobSource.ProgressFile && job.State.IsActive() && stillListed;
        if (!cancellable) return new Control();
        if (!host.AllowCancel)
        {
            var link = new Clickable(st.OpenSettings) { Child = T(L("打开设置", "Open Settings"), 10.5, FontWeight.Medium, Hue.Cyan) };
            var lockIcon = new Icon("lock", 10, Hue.Tertiary.B()) { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };
            link.VerticalAlignment = VerticalAlignment.Center;
            link.Margin = new Thickness(6, 0, 0, 0);
            var hint = T(L($"如需在这里取消任务，请先在设置中为「{host.DisplayName}」开启「允许取消任务」", $"To cancel jobs here, enable “Allow Cancelling” for {host.DisplayName} in Settings"), 10.5, color: Hue.Tertiary);
            DockPanel.SetDock(lockIcon, Dock.Left);
            DockPanel.SetDock(link, Dock.Right);
            return new DockPanel { LastChildFill = true, Children = { lockIcon, link, hint } };
        }
        switch (s.Stage)
        {
            case CancelStageKind.Idle:
                var title = job.Array != null ? L("按住以取消整个数组", "Hold to cancel array")
                    : job.Source == JobSource.Slurm ? L("按住以取消作业", "Hold to cancel job") : L("按住以终止进程", "Hold to stop process");
                return Row(0, Spacer, new HoldToConfirm(title, Hue.Coral, 1.5, () => { s.Stage = CancelStageKind.Confirm; s.Force = false; st.RequestRebuild(); }));
            case CancelStageKind.Confirm:
                return ConfirmRow(host, job, sampledAt, s);
            case CancelStageKind.Running:
                return Row(6, Spacer, new MiniSpinner(10), T(L("正在执行…", "Running…"), 11, color: Hue.Secondary));
            default:
                var o = s.Outcome!;
                var msg = o.Done
                    ? H(5, new Icon("check", 11, Hue.Mint.B(), 3), T(o.Message, 11, color: Hue.Mint))
                    : H(5, new Icon("warningFill", 11, Hue.Amber.B()), T(L($"没有执行：{o.Message}", $"Not executed: {o.Message}"), 11, color: Hue.Amber));
                Control? force = s.WasTerm && o.Done && job.Source == JobSource.Process
                    ? new HoldToConfirm(L("仍未退出？按住强制结束", "Still running? Hold to force kill"), Hue.Coral, 2, () => { s.Stage = CancelStageKind.Confirm; s.Force = true; st.RequestRebuild(); })
                    : null;
                return Row(8, Fill(msg), force);
        }
    }

    Control ConfirmRow(HostConfig host, RemoteJob job, DateTime? sampledAt, JobDetailState s)
    {
        var cmd = s.Force ? $"kill -KILL {job.Id}" : job.Source == JobSource.Slurm ? $"{host.Kind.CancelCommand()} {job.Id}" : $"kill -TERM {job.Id}";
        var target = job.Array is { } a
            ? L($"整个数组「{job.Name}」（运行 {a.Running.Count} + 排队 {a.Pending} 个元素）", $"the whole array “{job.Name}” ({a.Running.Count} running + {a.Pending} pending)")
            : L($"「{job.Name}」", $"“{job.Name}”");
        var text = V(1,
            T(s.Force ? L($"确定要在 {host.DisplayName} 上强制结束{target}吗？", $"Force-kill {target} on {host.DisplayName}?")
                      : L($"确定要在 {host.DisplayName} 上取消{target}吗？", $"Cancel {target} on {host.DisplayName}?"), 11, FontWeight.SemiBold),
            T(L($"将执行：{cmd}　执行前会再次核对任务是否还是同一个", $"Will run: {cmd}  — the job is re-checked first"), 9.5, color: Hue.Tertiary, mono: true));
        var confirm = new Clickable(async () =>
        {
            s.Stage = CancelStageKind.Running;
            st.RequestRebuild();
            var r = await engine.Cancel(host, job, sampledAt, s.Force);
            s.Outcome = r;
            s.WasTerm = !s.Force;
            s.Stage = CancelStageKind.Result;
            st.RequestRebuild();
        })
        {
            CornerRadius = new CornerRadius(100),
            Padding = new Thickness(10, 4),
            Normal = Hue.Coral,
            Hover = Hue.Coral.WithAlpha(0.85),
            Child = T(s.Force ? L("确认强制结束", "Force Kill") : L("确认取消", "Cancel It"), 10.5, FontWeight.Bold, Colors.Black),
        };
        return Row(10, new Icon("warningFill", 13, Hue.Coral.B()), Fill(text),
            PillButton(L("不了", "Never mind"), Hue.Secondary, () => { s.Stage = CancelStageKind.Idle; st.RequestRebuild(); }), confirm);
    }

    // MARK: - 数组作业概览

    Control ArrayOverview(RemoteJob job, ArrayInfo a, Action<RemoteJob> open)
    {
        Control Stat(string label, int v, Color c) => V(1, T($"{v}", 17, FontWeight.SemiBold, c), T(label, 10, color: Hue.Tertiary));
        var stats = Row(18, Stat(L("总数", "Total"), a.Total, Hue.Text), Stat(L("成功", "Done"), a.Done, Hue.Mint),
            Stat(L("失败", "Failed"), a.Failed, a.Failed > 0 ? Hue.Coral : Hue.Tertiary),
            Stat(L("运行中", "Running"), a.Running.Count, Hue.Cyan), Stat(L("排队中", "Pending"), a.Pending, Hue.Amber), Spacer,
            T(a.Accurate ? L("已结束数量来自 sacct", "Finished counts from sacct") : L("已结束数量为 ServerIsland 运行期间观察到的", "Finished counts observed by ServerIsland"), 10, color: Hue.Tertiary));
        var list = V(4);
        if (a.Running.Count == 0) list.Children.Add(Centered(L("暂时没有正在运行的元素", "No running elements right now"), 20));
        foreach (var e in a.Running)
        {
            var el = e;
            list.Children.Add(new Clickable(() => open(el))
            {
                CornerRadius = new CornerRadius(9), Padding = new Thickness(10, 6), Normal = Hue.Card, Hover = Hue.W(0.09),
                Child = Row(10, T($"[{e.ArrayTask ?? "?"}]", 11, FontWeight.SemiBold, Hue.Cyan, mono: true).W(54), T($"#{e.Id}", 10, color: Hue.Tertiary, mono: true),
                    Fill(T(e.Detail, 10.5, color: Hue.Secondary)), T(e.Elapsed is { } x ? Format.Duration(x) : "", 10.5, color: Hue.Secondary),
                    new Icon("chevronRight", 9, Hue.Tertiary.B(), 3)),
            });
        }
        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,10,Auto,10,Auto,10,*") };
        g.Children.Add(stats);
        var bar = new ArrayBar { Array = a, BarHeight = 7 };
        Grid.SetRow(bar, 2); g.Children.Add(bar);
        var cap = T(L("运行中的元素 · 点击查看日志", "Running elements · click for log"), 10.5, FontWeight.SemiBold, Hue.Secondary);
        Grid.SetRow(cap, 4); g.Children.Add(cap);
        var sc = Scroll(list);
        Grid.SetRow(sc, 6); g.Children.Add(sc);
        return RoundedCard(g, 12, Hue.W(0.03), 12);
    }

    // MARK: - 历史记录

    public Control History(HostConfig host)
    {
        var s = st.StateFor(() => new HistoryState());
        if (!s.Started && !PreviewMode)
        {
            s.Started = true;
            _ = LoadHistory(host, s);
        }
        var source = s.Entries == null ? L("读取中…", "Loading…")
            : s.FromServer ? L("最近 24 小时来自 sacct，更早的是本机记录（保留 7 天）", "last 24 h from sacct, older from the local record (kept 7 days)")
            : L("本机记录（保留 7 天）", "local record (kept 7 days)");
        Control? trailing = null;
        if (s.Entries is { } es)
        {
            int failed = es.Count(e => e.JobState is JobState.Failed or JobState.Timeout);
            int done = es.Count(e => e.JobState == JobState.Completed);
            trailing = H(8, H(3, new Icon("check", 10, Hue.Mint.B(), 3), T($"{done}", 11, FontWeight.SemiBold, Hue.Mint)),
                            H(3, new Icon("xmark", 10, (failed > 0 ? Hue.Coral : Hue.Tertiary).B(), 3), T($"{failed}", 11, FontWeight.SemiBold, failed > 0 ? Hue.Coral : Hue.Tertiary)));
        }
        var list = V(4);
        if (s.Entries is { } entries)
        {
            if (entries.Count == 0) list.Children.Add(Centered(L("还没有结束的任务", "No finished jobs yet")));
            foreach (var e in entries) list.Children.Add(HistoryRow(host, e));
        }
        else list.Children.Add(Loading());
        return Rows("Auto,10,*", PageHeader(L("历史记录", "History"), host.DisplayName + " · " + source, Back, trailing), Scroll(list));
    }

    async Task LoadHistory(HostConfig host, HistoryState s)
    {
        var r = await engine.FetchHistory(host);
        if (s.Disposed) return;
        s.Entries = r.Entries;
        s.FromServer = r.FromServer;
        st.RequestRebuild();
    }

    static Control HistoryRow(HostConfig host, HistoryEntry e)
    {
        var state = e.JobState;
        bool unknown = e.State == HistoryEntry.EndedUnknown;
        var c = unknown ? Hue.Secondary : Hue.For(state);
        var icon = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = c.WithAlpha(0.15).B(),
            Child = unknown ? T("?", 10, FontWeight.Bold, c).HA(HorizontalAlignment.Center)
                : new Icon(state is JobState.Failed or JobState.Timeout ? "xmark" : state == JobState.Cancelled ? "minus" : "check", 9.5, c.B(), 3)
            { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        var left = new ShrinkRow(10, 1, icon, T(e.Name, 12, FontWeight.Medium), T(e.Id, 9.5, color: Hue.Tertiary, mono: true),
            e.Note != null ? T(e.Note, 9.5, color: Hue.Tertiary) : null);
        var right = H(10, T(e.StateLabel, 10.5, FontWeight.Medium, c));
        if (e.ExitCode is { Length: > 0 } x && x != "0:0") right.Children.Add(T($"exit {x}", 9.5, color: Hue.Tertiary, mono: true));
        var el = T(e.Elapsed is { } d ? Format.Duration(d) : "—", 10.5, color: Hue.Secondary).W(64);
        el.TextAlignment = TextAlignment.Right;
        var when = T(Format.Relative(e.EndedAt), 10.5, color: Hue.Tertiary).W(58).Tip(e.EndedAt.ToString("g"));
        when.TextAlignment = TextAlignment.Right;
        right.Children.Add(el);
        right.Children.Add(when);
        Control top = Row(6, Fill(left), right);
        if (e.Dir is not { Length: > 0 } dir) return RoundedCard(top, 10, Hue.Card, 0).WithPadding(10, 6);
        // 工作目录：复制，或在终端里 ssh 到这个目录
        var path = new TextBlock
        {
            Text = dir, FontSize = 9.5, FontFamily = Hue.Mono, Foreground = Hue.Tertiary.B(),
            TextTrimming = TextTrimming.PrefixCharacterEllipsis, TextWrapping = TextWrapping.NoWrap, VerticalAlignment = VerticalAlignment.Center,
        }.Tip(dir);
        var dirRow = Row(6, new Icon("folder", 9, Hue.Tertiary.B(), 1.8), Fill(path),
            CopyButton(dir, L("复制目录", "Copy directory")),
            SmallIconButton("terminal", L("在终端中打开（ssh 到这个目录）", "Open in Terminal (ssh to this directory)"), () => Shell.OpenShellInTerminal(host, dir)));
        dirRow.Margin = new Thickness(30, 0, 0, 0);
        return RoundedCard(V(3, top, dirRow), 10, Hue.Card, 0).WithPadding(10, 6);
    }

    // MARK: - 选择要监听的进程

    public Control Picker(HostConfig host)
    {
        var s = st.StateFor(() => new PickerState());
        if (!s.Started && !PreviewMode) { s.Started = true; _ = LoadProcs(host, s); }
        var list = V(4);
        if (s.Procs is { } procs)
        {
            if (procs.Count == 0) list.Children.Add(Centered(L("没有找到属于你的进程", "No processes of yours found")));
            foreach (var p in procs) list.Children.Add(PickerRow(host, p));
        }
        else list.Children.Add(Loading());
        var header = PageHeader(L("监听进程", "Watch a Process"),
            host.DisplayName + L(" · 按 GPU 显存和 CPU 排序；监听的进程结束时一定会提醒", " · sorted by VRAM and CPU; watched processes always alert when they end"), Back,
            IconButton("refresh", L("重新读取", "Reload"), () => _ = LoadProcs(host, s)));
        var foot = T(L($"也可以在 设置 → {host.DisplayName} → 监听的进程 里手动输入 PID。", $"You can also enter a PID in Settings → {host.DisplayName} → Watched Processes."), 10, color: Hue.Tertiary);
        return Rows("Auto,10,*,10,Auto", header, Scroll(list), foot);
    }

    async Task LoadProcs(HostConfig host, PickerState s)
    {
        s.Procs = null;
        st.RequestRebuild();
        var r = await engine.TopProcesses(host) ?? [];
        if (s.Disposed) return;
        s.Procs = r;
        st.RequestRebuild();
    }

    Control PickerRow(HostConfig host, RemoteJob p)
    {
        bool on = engine.IsWatched(host.Id, p.Id);
        var icon = new Border
        {
            Width = 20, Height = 20, CornerRadius = new CornerRadius(10), Background = (on ? Hue.Mint.WithAlpha(0.16) : Hue.W(0.05)).B(),
            Child = new Icon(on ? "eyeFill" : "eye", 11, (on ? Hue.Mint : Hue.Tertiary).B()) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        var tags = H(10);
        if (p.GpuMemoryMB is { } g) tags.Children.Add(T(L("显存 ", "VRAM ") + Format.Bytes(g * 1_048_576), 10, FontWeight.Medium, Hue.Cyan));
        if (p.CpuPercent is { } c) tags.Children.Add(T($"CPU {(int)c}%", 10, FontWeight.Medium, Hue.Secondary));
        if (p.MemoryBytes is { } m) tags.Children.Add(T(Format.Bytes(m), 10, FontWeight.Medium, Hue.Tertiary));
        var el = T(p.Elapsed is { } e ? Format.Duration(e) : "", 10.5, color: Hue.Tertiary).W(70);
        el.TextAlignment = TextAlignment.Right;
        tags.Children.Add(el);
        var left = new ShrinkRow(10, 1, icon, T(p.Name, 12, FontWeight.Medium), T($"pid {p.Id}", 9.5, color: Hue.Tertiary, mono: true));
        return new Clickable(() =>
        {
            if (on) engine.Unwatch(host.Id, p.Id); else engine.Watch(host.Id, p);
            st.RequestRebuild();
        })
        {
            CornerRadius = new CornerRadius(10), Padding = new Thickness(10, 6),
            Normal = on ? Hue.Mint.WithAlpha(0.08) : Hue.Card, Hover = on ? Hue.Mint.WithAlpha(0.12) : Hue.W(0.09),
            Child = Row(6, Fill(left), tags),
        }.Tip(p.Detail);
    }

    // MARK: - 全部任务

    public Control AllJobs(HostConfig host, Action<RemoteJob> open)
    {
        var s = st.StateFor(() => new AllJobsState());
        var snap = engine.Snapshots.GetValueOrDefault(host.Id) ?? new HostSnapshot();
        var jobs = snap.Jobs.Where(j => Matches(j, s)).ToList();

        if (s.SearchBox == null)
        {
            s.SearchBox = new TextBox
            {
                Watermark = L("搜索名称 / 作业号", "Search name / ID"),
                Width = 150, FontSize = 11.5, FontFamily = Hue.Sans,
                Background = Brushes.Transparent, BorderThickness = new Thickness(0), Padding = new Thickness(0),
                MinHeight = 0, VerticalAlignment = VerticalAlignment.Center, Foreground = Hue.Text.B(),
            };
            s.SearchBox.TextChanged += (_, _) => { s.Query = s.SearchBox.Text ?? ""; st.RequestRebuild(); };
        }
        if (s.SearchBox.Parent is Panel old) old.Children.Remove(s.SearchBox);
        var search = Capsule(H(6, new Icon("search", 10.5, Hue.Tertiary.B()), s.SearchBox), Hue.W(0.09), 10, 4);
        var header = PageHeader(L("全部任务", "All Jobs"),
            L($"{host.DisplayName} · 运行 {snap.RunningCount} · 排队 {snap.PendingCount}", $"{host.DisplayName} · {snap.RunningCount} running · {snap.PendingCount} pending"), Back, search);

        var filters = H(6);
        foreach (var f in Enum.GetValues<JobsFilter>())
        {
            var label = f switch { JobsFilter.All => L("全部", "All"), JobsFilter.Running => L("运行中", "Running"), JobsFilter.Pending => L("排队中", "Pending"), _ => L("数组", "Arrays") };
            var ff = f;
            filters.Children.Add(new Clickable(() => { s.Filter = ff; st.RequestRebuild(); })
            {
                CornerRadius = new CornerRadius(100), Padding = new Thickness(10, 3.5),
                Normal = Hue.W(s.Filter == f ? 0.14 : 0.04), Hover = Hue.W(s.Filter == f ? 0.18 : 0.09),
                Child = T(label, 10.5, FontWeight.SemiBold, s.Filter == f ? Hue.Text : Hue.Tertiary),
            });
        }
        var filterRow = Row(6, filters, Spacer, T(L($"{jobs.Count} 项", $"{jobs.Count} items"), 10.5, color: Hue.Tertiary));

        var list = new StackPanel { Spacing = IslandLayout.JobGap, Margin = new Thickness(6, 0) };
        if (jobs.Count == 0) list.Children.Add(Centered(L("没有匹配的任务", "No matching jobs"), 30));
        foreach (var j in jobs)
        {
            var job = j;
            list.Children.Add(HostCardView.JobRowButton(job, host.Kind, snap.LastUpdate, () => open(job), st).Hgt(IslandLayout.JobRow));
        }
        var scroll = Scroll(list);
        var restore = s.ScrollOffset;
        scroll.ScrollChanged += (_, _) => s.ScrollOffset = scroll.Offset;
        Dispatcher.UIThread.Post(() => scroll.Offset = restore, DispatcherPriority.Loaded);
        return Rows("Auto,10,Auto,10,*", header, filterRow, scroll);
    }

    static bool Matches(RemoteJob j, AllJobsState s)
    {
        switch (s.Filter)
        {
            case JobsFilter.Running when j.RunningUnits == 0: return false;
            case JobsFilter.Pending when j.PendingUnits == 0: return false;
            case JobsFilter.Array when j.Array == null: return false;
        }
        var q = s.Query.Trim().ToLowerInvariant();
        if (q.Length == 0) return true;
        return j.Name.ToLowerInvariant().Contains(q) || j.Id.Contains(q) || j.Detail.ToLowerInvariant().Contains(q);
    }

    // MARK: - Slurm 分区空闲资源

    public Control PartitionsPage(HostConfig host)
    {
        var s = st.StateFor(() => new PartitionsState());
        if (!s.Started && !PreviewMode) { s.Started = true; _ = LoadPartitions(host, s, false); }
        // 整个集群的加速卡名字（GPU / DCU / DCU/GPU）
        var gpuLabel = PartitionStat.Label((s.Stats ?? []).SelectMany(p => p.GpuKinds));
        var subtitle = s.Loading && s.Stats == null ? L("查询中…", "Querying…")
            : s.Stats == null ? L("按需查询，不参与轮询", "On demand, not polled")
            : L($"查询于 {Format.Relative(s.At)} · 按空闲 {gpuLabel} 排序", $"queried {Format.Relative(s.At)} · sorted by idle {gpuLabel}s");
        var header = PageHeader(L("分区空闲资源", "Free Partition Resources"), host.DisplayName + " · " + subtitle, Back,
            IconButton("refresh", L("重新查询（sinfo）", "Query again (sinfo)"), () => _ = LoadPartitions(host, s, true), spinning: s.Loading));
        Control totals = new Control();
        if (s.Stats is { } stats)
        {
            Control Total(string label, int idle, int all, Color c) => H(5, T(label, 10.5, color: Hue.Tertiary),
                T($"{idle}", 14, FontWeight.SemiBold, idle > 0 ? c : Hue.Tertiary), T($"/ {all}", 10.5, color: Hue.Tertiary));
            totals = Row(16, Total(L($"空闲 {gpuLabel}", $"Idle {gpuLabel}"), stats.Sum(p => p.GpuIdle), stats.Sum(p => p.GpuTotal), Hue.Cyan),
                Total(L("空闲 CPU", "Idle CPU"), stats.Sum(p => p.CpuIdle), stats.Sum(p => p.CpuTotal), Hue.Mint), Spacer,
                T(L("同一节点可能属于多个分区，合计会重复计算", "Nodes in several partitions are counted more than once"), 9.5, color: Hue.Tertiary));
        }
        var list = V(5);
        if (s.Error is { } err) list.Children.Add(H(6, new Icon("warningFill", 11, Hue.Amber.B()), T(err, 11, color: Hue.Amber)).HA(HorizontalAlignment.Center).Margin(0, 30, 0, 0));
        else if (s.Stats is { } st2) foreach (var p in st2) list.Children.Add(PartitionRow(p));
        else list.Children.Add(Loading());
        return Rows("Auto,10,Auto,10,*", header, totals, Scroll(list));
    }

    async Task LoadPartitions(HostConfig host, PartitionsState s, bool force)
    {
        s.Loading = true;
        st.RequestRebuild();
        var r = await engine.FetchPartitions(host, force);
        if (s.Disposed) return;
        s.Stats = r.Stats; s.At = r.At; s.Error = r.Error; s.Loading = false;
        st.RequestRebuild();
    }

    static Control PartitionRow(PartitionStat p)
    {
        var top = H(6, T(p.Name, 12.5, FontWeight.SemiBold, p.Available ? Hue.Text : Hue.Tertiary));
        if (p.IsDefault) top.Children.Add(Capsule(T(L("默认", "default"), 8.5, FontWeight.Bold, Hue.Violet), Hue.Violet.WithAlpha(0.15), 5, 1.5));
        if (!p.Available) top.Children.Add(Capsule(T(L("已关闭", "down"), 8.5, FontWeight.Bold, Hue.Coral), Hue.Coral.WithAlpha(0.15), 5, 1.5));
        if (p.GpuModels.Count > 0) top.Children.Add(T(string.Join(", ", p.GpuModels), 9.5, color: Hue.Tertiary, mono: true));
        var nodes = L($"节点 空闲 {p.IdleNodes} · 部分 {p.MixNodes} · 满 {p.AllocNodes}", $"nodes idle {p.IdleNodes} · mixed {p.MixNodes} · full {p.AllocNodes}");
        if (p.DownNodes > 0) nodes += L($" · 不可用 {p.DownNodes}", $" · down {p.DownNodes}");
        var right = H(10, T(nodes, 10, color: Hue.Tertiary));
        if (p.TimeLimit.Length > 0) right.Children.Add(T(L("上限 ", "limit ") + (p.TimeLimit == "infinite" ? L("不限", "none") : p.TimeLimit), 10, color: Hue.Tertiary));
        Control Meter(string label, int idle, int total, Color c)
        {
            var t = T(L($"空闲 {idle}/{total}", $"idle {idle}/{total}"), 10.5, FontWeight.Medium, idle > 0 ? Hue.Secondary : Hue.Tertiary).W(92);
            t.TextAlignment = TextAlignment.Right;
            return Row(6, T(label, 9.5, FontWeight.SemiBold, Hue.Tertiary).MinW(26), Fill(new SlimBar { Fraction = total > 0 ? (double)idle / total : 0, Fill = c.B(), BarHeight = 5 }), t);
        }
        var meters = new Grid { ColumnDefinitions = new ColumnDefinitions(p.GpuTotal > 0 ? "*,14,*" : "*") };
        if (p.GpuTotal > 0)
        {
            meters.Children.Add(Meter(p.GpuLabel, p.GpuIdle, p.GpuTotal, Hue.Cyan));
            var cpu = Meter("CPU", p.CpuIdle, p.CpuTotal, Hue.Mint);
            Grid.SetColumn(cpu, 2);
            meters.Children.Add(cpu);
        }
        else meters.Children.Add(Meter("CPU", p.CpuIdle, p.CpuTotal, Hue.Mint));
        var card = RoundedCard(V(6, Row(6, Fill(top), right), meters), 10, Hue.Card, 0).WithPadding(12, 8);
        card.Opacity = p.Available ? 1 : 0.6;
        return card;
    }
}

public static class BorderExtensions
{
    public static Border WithPadding(this Border b, double h, double v) { b.Padding = new Thickness(h, v); return b; }
}

/// 按住一段时间才会触发的按钮（防误触）。
public sealed class HoldToConfirm : Border
{
    readonly string _title;
    readonly Color _tint;
    readonly double _duration;
    readonly Action _action;
    readonly Border _fill;
    readonly TextBlock _text;
    DispatcherTimer? _timer;
    DateTime _start;

    public HoldToConfirm(string title, Color tint, double duration, Action action)
    {
        _title = title; _tint = tint; _duration = duration; _action = action;
        Width = 190; Height = 28;
        CornerRadius = new CornerRadius(14);
        Background = tint.WithAlpha(0.12).B();
        ClipToBounds = true;
        Cursor = new Cursor(StandardCursorType.Hand);
        _fill = new Border { Background = tint.WithAlpha(0.35).B(), HorizontalAlignment = HorizontalAlignment.Left, Width = 0, CornerRadius = new CornerRadius(14) };
        _text = Kit.T(title, 11, FontWeight.SemiBold, tint);
        var label = Kit.H(6, new Icon("hand", 11, tint.B(), 2.3), _text).HA(HorizontalAlignment.Center);
        var g = new Grid();
        g.Children.Add(_fill);
        g.Children.Add(label);
        Child = g;
        this.Tip(L("为防止误触，需要按住 ", "To avoid accidents, hold for ") + Text.Fmt(duration, "0.0") + L(" 秒", " s"));
        PointerPressed += (_, e) =>
        {
            if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
            e.Handled = true;
            e.Pointer.Capture(this);
            _start = DateTime.Now;
            _text.Text = L("继续按住…", "Keep holding…");
            _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Render, (_, _) => Tick());
            _timer.Start();
        };
        PointerReleased += (_, _) => Stop();
        PointerCaptureLost += (_, _) => Stop();
    }

    void Tick()
    {
        var p = Math.Min(1, (DateTime.Now - _start).TotalSeconds / _duration);
        _fill.Width = Bounds.Width * p;
        if (p >= 1)
        {
            Stop();
            _action();
        }
    }

    void Stop()
    {
        _timer?.Stop();
        _timer = null;
        _fill.Width = 0;
        _text.Text = _title;
    }
}
