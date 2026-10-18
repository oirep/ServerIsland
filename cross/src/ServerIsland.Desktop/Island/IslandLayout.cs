using Avalonia;
using ServerIsland.Core;

namespace ServerIsland.Desktop.Island;

public enum IslandMode
{
    /// 什么都没有：只留一条很细的把手（Windows / Linux 没有硬件刘海）
    Hidden,
    /// 两侧的小翅膀
    Collapsed,
    /// 事件提示
    Toast,
    /// 悬停展开的面板
    Expanded,
}

/// 虚拟刘海的几何参数。Windows / Linux 没有硬件刘海，中间的空隙宽度为 0。
public sealed record NotchGeometry(double NotchWidth, double NotchHeight)
{
    public static readonly NotchGeometry Virtual = new(0, 32);
}

/// 所有尺寸都是确定的（每种行固定高度），这样展开动画可以一次到位，不需要先渲染再测量。（与 Swift 版 IslandLayout.swift 一致）
public static class IslandLayout
{
    public const double Wing = 62;
    public const double ExpandedMinWidth = 640;
    public const double ToastMinWidth = 420;
    public const double ToastBody = 60;
    public const double SidePad = 14;
    public const double TopGap = 8;
    public const double BottomPad = 14;
    public const double MaxContentHeight = 540;

    public const double CardPad = 12;
    public const double CardHeader = 20;
    public const double SectionGap = 10;
    public const double MetricsRow = 16;
    public const double JobRow = 34;
    public const double JobGap = 6;
    public const double MoreRow = 14;
    public const double EmptyRow = 16;
    public const double ProblemRow = 28;
    public const double WarningRow = 15;
    public const double CardGap = 8;
    public const double IdleRow = 36;
    public const int MaxJobs = 5;
    public const double EmptyState = 104;
    /// 二级页面（详情 / 历史 / 监听）的固定高度。
    public const double PageHeight = 420;
    /// 没有任务时留在屏幕顶端的把手（Windows / Linux 上没有硬件刘海可以藏）。
    public const double HandleWidth = 96, HandleHeight = 7;

    public sealed record CardParts
    {
        public bool Metrics, Problem, Connecting, EmptyJobs, Paused;
        public int JobRows, More, Warnings;
    }

    public static CardParts Parts(HostConfig host, HostSnapshot snap)
    {
        var p = new CardParts { Paused = host.Paused };
        if (host.Paused && snap.LastUpdate == null && !snap.IsRefreshing) return p;
        if (snap.Health.IsProblem) return p with { Problem = true };
        if (snap.LastUpdate == null) return p with { Connecting = true };
        var m = snap.Metrics;
        bool metrics = (host.ShowCPU && m.CpuPercent != null) || (host.ShowMemory && m.MemoryFraction != null) || (host.ShowGPU && snap.Gpus.Count > 0);
        p = p with { Metrics = metrics, Warnings = snap.Warnings.Count };
        if (host.WatchJobs || snap.Jobs.Count > 0)
            p = p with { JobRows = Math.Min(snap.Jobs.Count, MaxJobs), More = Math.Max(0, snap.Jobs.Count - MaxJobs), EmptyJobs = snap.Jobs.Count == 0 };
        return p;
    }

    public static double CardHeight(CardParts p)
    {
        double h = CardPad * 2 + CardHeader;
        if (p.Paused) h += SectionGap + EmptyRow;
        if (p.Problem) h += SectionGap + ProblemRow;
        if (p.Connecting) h += SectionGap + EmptyRow;
        if (p.Metrics) h += SectionGap + MetricsRow;
        if (p.Warnings > 0) h += 6 + p.Warnings * WarningRow;
        if (p.JobRows > 0) h += SectionGap + p.JobRows * JobRow + (p.JobRows - 1) * JobGap;
        if (p.More > 0) h += 4 + MoreRow;
        if (p.EmptyJobs) h += SectionGap + EmptyRow;
        return h;
    }

    /// 空闲：已连上、没有任务、没有问题和警告、磁盘不紧张。暂停且没有任务的也算。
    public static bool IsIdle(HostConfig host, HostSnapshot snap)
    {
        if (snap.Jobs.Count > 0 || snap.Health.IsProblem || snap.Warnings.Count > 0) return false;
        if (snap.LastUpdate == null) return host.Paused && !snap.IsRefreshing;
        return !snap.Disks.Any(d => d.Fraction >= 0.8);
    }

    /// 把机器分成"显示卡片"和"合并成一行的空闲机器"。全部空闲时不合并。
    public static (List<(HostConfig, HostSnapshot)> Cards, List<(HostConfig, HostSnapshot)> Idle) Groups(List<(HostConfig Host, HostSnapshot Snap)> hosts, bool fold)
    {
        if (!fold) return (hosts, []);
        var idle = hosts.Where(h => IsIdle(h.Host, h.Snap)).ToList();
        if (idle.Count == 0 || idle.Count >= hosts.Count) return (hosts, []);
        return (hosts.Where(h => !IsIdle(h.Host, h.Snap)).ToList(), idle);
    }

    public static double ContentHeight(List<(HostConfig Host, HostSnapshot Snap)> hosts, bool fold = false, bool showIdle = false)
    {
        if (hosts.Count == 0) return EmptyState;
        var (cards, idle) = Groups(hosts, fold);
        var shown = cards.ToList();
        if (showIdle) shown.AddRange(idle);
        double h = shown.Sum(x => CardHeight(Parts(x.Item1, x.Item2))) + Math.Max(0, shown.Count - 1) * CardGap;
        if (idle.Count > 0) h += CardGap + IdleRow;
        return h;
    }

    public static bool WingsVisible(MonitorEngine engine, CollapsedStyle style) => style switch
    {
        CollapsedStyle.Always => engine.OrderedHosts.Count > 0,
        CollapsedStyle.Never => false,
        _ => engine.TotalRunning + engine.TotalPending > 0 || engine.HasProblem,
    };

    public static IslandMode Mode(bool hovering, MonitorEngine engine, CollapsedStyle style)
    {
        if (hovering) return IslandMode.Expanded;
        if (engine.CurrentEvent != null) return IslandMode.Toast;
        return WingsVisible(engine, style) ? IslandMode.Collapsed : IslandMode.Hidden;
    }

    public sealed record ShapeSpec(double Width, double Height, double TopRadius, double BottomRadius, bool Scrolls = false);

    /// floating = 桌宠模式下浮在小章鱼旁边的面板（没有和刘海衔接的"耳朵"，四角都是圆角）。
    public static ShapeSpec Spec(IslandMode mode, NotchGeometry g, double contentHeight, bool floating = false)
    {
        double nw = g.NotchWidth, nh = g.NotchHeight;
        switch (mode)
        {
            case IslandMode.Hidden:
                return new ShapeSpec(HandleWidth, HandleHeight, 0, HandleHeight / 2);
            case IslandMode.Collapsed:
            {
                const double ear = 6;
                return new ShapeSpec(nw + 2 * Wing + 2 * ear, nh, ear, 10);
            }
            case IslandMode.Toast:
            {
                double ear = floating ? 0 : 10;
                double w = Math.Max(nw + 2 * 120, ToastMinWidth);
                return new ShapeSpec(w + 2 * ear, nh + ToastBody, ear, 22);
            }
            default:
            {
                double ear = floating ? 0 : 14;
                double w = Math.Max(nw + 2 * 200, ExpandedMinWidth);
                double body = Math.Min(contentHeight, MaxContentHeight);
                return new ShapeSpec(w + 2 * ear, nh + TopGap + body + BottomPad, ear, 26, contentHeight > MaxContentHeight);
            }
        }
    }

    /// 窗口的固定尺寸，足以容纳最大展开状态和阴影。
    public static Size PanelSize(NotchGeometry g)
    {
        double w = Math.Max(g.NotchWidth + 2 * 200, ExpandedMinWidth) + 28 + 80;
        return new Size(w, g.NotchHeight + TopGap + MaxContentHeight + BottomPad + 40);
    }
}
