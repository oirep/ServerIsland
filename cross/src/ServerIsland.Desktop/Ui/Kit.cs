using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using ServerIsland.Core;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop.Ui;

/// 一次界面构建期间登记的"每秒更新"回调（运行时长、相对时间等），避免为了走字每秒重建整棵界面树。
public sealed class LiveScope
{
    [ThreadStatic] static LiveScope? _current;
    public static LiveScope? Current => _current;
    public readonly List<Action> Updaters = [];

    public static LiveScope Begin() => _current = new LiveScope();
    public static void End() => _current = null;

    public static void Register(Action a) => _current?.Updaters.Add(a);

    public void Tick()
    {
        foreach (var u in Updaters) { try { u(); } catch { } }
    }
}

/// 刘海里的小控件（深色）。尺寸、颜色、字号与 SwiftUI 版对应。
public static class Kit
{
    public static TextBlock T(string text, double size, FontWeight weight = FontWeight.Normal, Color? color = null, bool mono = false,
                              TextTrimming? trim = null)
    {
        return new TextBlock
        {
            Text = text,
            FontSize = size * Hue.FontScale,
            FontWeight = weight,
            Foreground = (color ?? Hue.Text).B(),
            FontFamily = mono ? Hue.Mono : Hue.Sans,
            TextTrimming = trim ?? TextTrimming.CharacterEllipsis,
            TextWrapping = TextWrapping.NoWrap,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// 每秒刷新文字的 TextBlock。
    public static TextBlock LiveT(Func<string> text, double size, FontWeight weight = FontWeight.Normal, Color? color = null, bool mono = false)
    {
        var t = T(text(), size, weight, color, mono);
        LiveScope.Register(() => { var s = text(); if (t.Text != s) t.Text = s; });
        return t;
    }

    public static TextBlock Middle(this TextBlock t) { t.TextTrimming = TextTrimming.PrefixCharacterEllipsis; return t; }
    public static TextBlock Head(this TextBlock t) { t.TextTrimming = TextTrimming.LeadingCharacterEllipsis; return t; }

    public static T Tip<T>(this T c, string? tip) where T : Control
    {
        if (!string.IsNullOrEmpty(tip)) ToolTip.SetTip(c, tip);
        return c;
    }

    public static T W<T>(this T c, double width) where T : Control { c.Width = width; return c; }
    public static T Hgt<T>(this T c, double height) where T : Control { c.Height = height; return c; }
    public static T MinW<T>(this T c, double width) where T : Control { c.MinWidth = width; return c; }
    public static T Op<T>(this T c, double opacity) where T : Control { c.Opacity = opacity; return c; }
    public static T Margin<T>(this T c, double l, double t, double r, double b) where T : Control { c.Margin = new Thickness(l, t, r, b); return c; }
    public static T HA<T>(this T c, HorizontalAlignment a) where T : Control { c.HorizontalAlignment = a; return c; }
    public static T VA<T>(this T c, VerticalAlignment a) where T : Control { c.VerticalAlignment = a; return c; }

    public static StackPanel H(double spacing, params Control?[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = spacing, VerticalAlignment = VerticalAlignment.Center };
        foreach (var c in children) if (c != null) p.Children.Add(c);
        return p;
    }

    public static StackPanel V(double spacing, params Control?[] children)
    {
        var p = new StackPanel { Orientation = Orientation.Vertical, Spacing = spacing };
        foreach (var c in children) if (c != null) p.Children.Add(c);
        return p;
    }

    /// 弹性空白（SwiftUI 的 Spacer），用在 Row(...) 里。
    public static readonly object Spacer = new();

    /// 横向一行：Spacer 表示弹性空白；Fill(x) 表示这一项占满剩余宽度（可以被截断）；null 直接跳过（方便写条件项）。
    public static Grid Row(double spacing, params object?[] items)
    {
        var g = new Grid { VerticalAlignment = VerticalAlignment.Stretch };
        int col = 0;
        items = items.Where(i => i != null).ToArray();
        bool hasStar = items.Any(i => i == Spacer || i is FillItem);
        foreach (var item in items)
        {
            if (col > 0 && spacing > 0) { g.ColumnDefinitions.Add(new ColumnDefinition(spacing, GridUnitType.Pixel)); col++; }
            switch (item)
            {
                case var sp when sp == Spacer:
                    g.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
                    break;
                case FillItem f:
                    g.ColumnDefinitions.Add(new ColumnDefinition(f.Weight, GridUnitType.Star));
                    Grid.SetColumn(f.Control, col);
                    g.Children.Add(f.Control);
                    break;
                case Control c:
                    g.ColumnDefinitions.Add(new ColumnDefinition(GridLength.Auto));
                    Grid.SetColumn(c, col);
                    c.VerticalAlignment = c.VerticalAlignment == VerticalAlignment.Stretch ? VerticalAlignment.Center : c.VerticalAlignment;
                    g.Children.Add(c);
                    break;
            }
            col++;
        }
        if (!hasStar) g.ColumnDefinitions.Add(new ColumnDefinition(1, GridUnitType.Star));
        return g;
    }

    public sealed record FillItem(Control Control, double Weight = 1);
    public static FillItem Fill(Control c, double weight = 1) => new(c, weight);

    public static Control Gap(double h) => new Control { Height = h };

    public static Border Capsule(Control child, Color bg, double padH = 6, double padV = 2)
    {
        return new Border
        {
            Background = bg.B(),
            CornerRadius = new CornerRadius(100),
            Padding = new Thickness(padH, padV),
            Child = child,
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    public static Border RoundedCard(Control child, double radius = 12, Color? bg = null, double pad = 10)
    {
        return new Border
        {
            Background = (bg ?? Hue.Card).B(),
            CornerRadius = new CornerRadius(radius),
            Padding = new Thickness(pad),
            Child = child,
        };
    }

    // MARK: - 小部件

    public static Control StatusDot(Color c, double size = 7) => new Border
    {
        Width = size,
        Height = size,
        CornerRadius = new CornerRadius(size / 2),
        Background = c.B(),
        BoxShadow = new BoxShadows(new BoxShadow { Blur = size * 1.2, Color = c.WithAlpha(0.8) }),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static Control KindBadge(HostKind kind)
    {
        var c = kind.IsScheduler() ? Hue.Violet : Hue.Cyan;
        var t = T(kind.Badge(), 8, FontWeight.Bold, c);
        t.LetterSpacing = 0.6;
        return Capsule(t, c.WithAlpha(0.14), 5, 1.5);
    }

    /// 单台服务器的运行 / 排队数量（数组按元素算），为 0 的那一项不显示。
    public static Control JobCountChips(int running, int pending, bool dimmed = false)
    {
        var row = H(7);
        if (running > 0) row.Children.Add(H(2.5, new Icon("bolt", 9, Hue.Mint.B()), T($"{running}", 10, FontWeight.SemiBold, Hue.Mint)));
        if (pending > 0) row.Children.Add(H(2.5, new Icon("hourglass", 9, Hue.Amber.B(), 2.6), T($"{pending}", 10, FontWeight.SemiBold, Hue.Amber)));
        var cap = Capsule(row, Hue.W(0.06), 6, 1.5);
        cap.Opacity = dimmed ? 0.5 : 1;
        return cap.Tip(L($"这台服务器：{running} 个运行中 · {pending} 个排队中\n数组作业按元素计数，所以可能比列表的行数多",
                         $"This server: {running} running · {pending} pending\nArray jobs count each element, so this can exceed the rows shown"));
    }

    /// "CPU 34% ▬▬▬" 样式的小指标。
    public static Control MetricChip(string label, double fraction, string valueText, string help = "")
    {
        return H(6,
            T(label, 9.5, FontWeight.SemiBold, Hue.Tertiary),
            new SlimBar { Fraction = fraction, Fill = Hue.Load(fraction).B(), BarHeight = 4, Width = 44 },
            T(valueText, 10.5, FontWeight.Medium, Hue.Secondary).MinW(28)).Tip(help);
    }

    /// 每张 GPU 一个小方块，填充高度 = 利用率，显存快满时顶部一条琥珀色线。
    public static Control GPUCells(List<GPUStat> gpus)
    {
        var cells = H(3);
        foreach (var g in gpus.Take(16))
        {
            var util = L("利用率", "util") + $" {(int)g.Utilization}%";
            var mem = L("显存", "VRAM") + $" {(int)(g.MemoryUsedMB / 1024)}/{(int)(g.MemoryTotalMB / 1024)} GB";
            var temp = g.Temperature is { } t ? $" · {(int)t}°C" : "";
            cells.Children.Add(new GpuCell { Gpu = g, Width = gpus.Count > 8 ? 6 : 8, Height = 14 }.Tip($"GPU {g.Index} · {g.Name}\n{util} · {mem}{temp}"));
        }
        int busy = gpus.Count(g => g.Utilization > 5 || g.MemoryFraction > 0.1);
        return H(6, T("GPU", 9.5, FontWeight.SemiBold, Hue.Tertiary), cells,
                 T(L($"{gpus.Count - busy}/{gpus.Count} 空闲", $"{gpus.Count - busy}/{gpus.Count} idle"), 10, FontWeight.Medium, Hue.Secondary));
    }

    /// GPU 数量少（1–2 张）时的详细指标：利用率条 + 显存 + 温度。
    public static Control GPUDetailChip(GPUStat g, bool showIndex)
    {
        var row = H(6,
            T(showIndex ? $"GPU{g.Index}" : "GPU", 9.5, FontWeight.SemiBold, Hue.Tertiary),
            new SlimBar { Fraction = g.Utilization / 100, Fill = Hue.Horizontal(Hue.Cyan, Hue.Mint), BarHeight = 4, Width = 44 },
            T($"{(int)g.Utilization}%", 10.5, FontWeight.Medium, Hue.Secondary),
            T($"{g.MemoryUsedMB / 1024:0.0}/{g.MemoryTotalMB / 1024:0}G", 10.5, FontWeight.Medium, g.MemoryFraction > 0.9 ? Hue.Amber : Hue.Secondary));
        if (g.Temperature is { } t) row.Children.Add(T($"{(int)t}°", 10.5, FontWeight.Medium, t >= 80 ? Hue.Coral : Hue.Tertiary));
        return row.Tip(GPUStat.ShortName(g.Name));
    }

    public static Control DiskChip(DiskStat disk, List<DiskStat> all)
    {
        var c = disk.Fraction >= 0.9 ? Hue.Coral : Hue.Amber;
        var tip = string.Join("\n", all.Select(d => L($"{d.Mount}  已用 {Format.Percent(d.Fraction)}，剩余 {Format.Bytes((d.TotalKB - d.UsedKB) * 1024)}",
                                                      $"{d.Mount}  {Format.Percent(d.Fraction)} used, {Format.Bytes((d.TotalKB - d.UsedKB) * 1024)} free")));
        return Capsule(H(4, new Icon("drive", 10, c.B()), T(Format.Percent(disk.Fraction), 10.5, FontWeight.SemiBold, c)), c.WithAlpha(0.14), 6, 2).Tip(tip);
    }

    /// 小号圆形图标按钮（刷新 / 设置）。
    public static Clickable IconButton(string icon, string help, Action action, bool active = false, bool spinning = false)
    {
        var ic = new Icon(icon, 12, (active ? Hue.Mint : Hue.Secondary).B(), 2.5);
        Control inner = spinning ? new Spinning(ic) : ic;
        var b = new Clickable(action)
        {
            Width = 24, Height = 24,
            CornerRadius = new CornerRadius(12),
            Normal = active ? Hue.Mint.WithAlpha(0.18) : Hue.W(0.07),
            Hover = active ? Hue.Mint.WithAlpha(0.26) : Hue.W(0.14),
            Child = inner,
        };
        b.HoverChanged = h => { if (!active) ic.Brush = (h ? Hue.Text : Hue.Secondary).B(); ic.InvalidateVisual(); };
        ic.HorizontalAlignment = HorizontalAlignment.Center;
        ic.VerticalAlignment = VerticalAlignment.Center;
        return (Clickable)b.Tip(help);
    }

    /// 卡片头部的小图标按钮（20×20，悬停才有底色）。
    public static Clickable SmallIconButton(string icon, string help, Action action, Color? tint = null, double size = 11)
    {
        var baseColor = tint ?? Hue.Tertiary;
        var ic = new Icon(icon, size, baseColor.B(), 2.5) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center };
        var b = new Clickable(action)
        {
            Width = 20, Height = 20,
            CornerRadius = new CornerRadius(10),
            Normal = Colors.Transparent,
            Hover = Hue.W(0.12),
            Child = ic,
        };
        b.HoverChanged = h => { ic.Brush = (h ? Hue.Text : baseColor).B(); ic.InvalidateVisual(); };
        return (Clickable)b.Tip(help);
    }

    public static Clickable PillButton(string title, Color tint, Action action)
    {
        return new Clickable(action)
        {
            CornerRadius = new CornerRadius(100),
            Padding = new Thickness(10, 4),
            Normal = tint.WithAlpha(0.16),
            Hover = tint.WithAlpha(0.28),
            Child = T(title, 10.5, FontWeight.SemiBold, tint),
            VerticalAlignment = VerticalAlignment.Center,
        };
    }

    /// 复制按钮：点击后短暂显示对勾。
    public static Clickable CopyButton(string value, string help, string? label = null)
    {
        var ic = new Icon("copy", 10.5, Hue.Tertiary.B(), 2.4) { VerticalAlignment = VerticalAlignment.Center };
        var text = label == null ? null : T(label, 10, FontWeight.Medium, Hue.Tertiary);
        var content = H(4, ic, text);
        Clickable? b = null;
        b = new Clickable(async () =>
        {
            await Clipboard.SetText(b!, value);
            var old = ic.Name2;
            content.Children[0] = new Icon("check", 10.5, Hue.Mint.B(), 2.6) { VerticalAlignment = VerticalAlignment.Center };
            if (text != null) { text.Text = L("已复制", "Copied"); text.Foreground = Hue.Mint.B(); }
            DispatcherTimer.RunOnce(() =>
            {
                content.Children[0] = ic;
                if (text != null) { text.Text = label; text.Foreground = Hue.Tertiary.B(); }
            }, TimeSpan.FromSeconds(1.2));
        })
        {
            CornerRadius = new CornerRadius(100),
            Padding = new Thickness(label == null ? 4 : 7, 3),
            MinHeight = 20, MinWidth = 20,
            Normal = label == null ? Colors.Transparent : Hue.W(0.05),
            Hover = Hue.W(0.10),
            Child = content,
            VerticalAlignment = VerticalAlignment.Center,
        };
        b.HoverChanged = h => { ic.Brush = (h ? Hue.Text : Hue.Tertiary).B(); ic.InvalidateVisual(); };
        return (Clickable)b.Tip(help);
    }
}

/// 剪贴板（Avalonia 的剪贴板挂在 TopLevel 上）。
public static class Clipboard
{
    public static async Task SetText(Visual anyVisual, string text)
    {
        var top = TopLevel.GetTopLevel(anyVisual);
        if (top?.Clipboard != null) await top.Clipboard.SetTextAsync(text);
    }
}

/// 可点击的区域：悬停变色、手形光标、点一下执行。比 Button 轻，样式完全自己控制。
public class Clickable : Border
{
    readonly Func<Task>? _asyncAction;
    readonly Action? _action;
    public Color Normal { get => _normal; set { _normal = value; if (!_hover) Background = value.B(); } }
    public Color Hover { get; set; } = Hue.W(0.1);
    public Action<bool>? HoverChanged;
    Color _normal = Colors.Transparent;
    bool _hover;

    public Clickable(Action action) : this() { _action = action; }
    public Clickable(Func<Task> action) : this() { _asyncAction = action; }

    Clickable()
    {
        Cursor = new Cursor(StandardCursorType.Hand);
        Background = Brushes.Transparent;
        PointerEntered += (_, _) => SetHover(true);
        PointerExited += (_, _) => SetHover(false);
        PointerReleased += OnReleased;
    }

    void SetHover(bool on)
    {
        _hover = on;
        Background = (on ? Hover : _normal).B();
        HoverChanged?.Invoke(on);
    }

    void OnReleased(object? sender, PointerReleasedEventArgs e)
    {
        if (e.InitialPressMouseButton != MouseButton.Left) return;
        var p = e.GetPosition(this);
        if (p.X < 0 || p.Y < 0 || p.X > Bounds.Width || p.Y > Bounds.Height) return;
        e.Handled = true;
        if (_action != null) _action();
        else if (_asyncAction != null) _ = _asyncAction();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        base.OnPointerPressed(e);
        if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) e.Handled = true;
    }
}

/// 细长进度条。Fraction 为 null 时只显示轨道。
public sealed class SlimBar : Control
{
    public double? Fraction { get; set; }
    public IBrush Fill { get; set; } = Hue.Progress;
    public double BarHeight { get; set; } = 4;

    public SlimBar() { VerticalAlignment = VerticalAlignment.Center; }

    protected override Size MeasureOverride(Size availableSize) => new(0, BarHeight);

    public override void Render(DrawingContext ctx)
    {
        var w = Bounds.Width;
        var h = BarHeight;
        var r = h / 2;
        ctx.DrawRectangle(Hue.Track.B(), null, new RoundedRect(new Rect(0, 0, w, h), r));
        if (Fraction is { } f)
        {
            var fw = Math.Max(h, w * Math.Clamp(f, 0, 1));
            ctx.DrawRectangle(Fill, null, new RoundedRect(new Rect(0, 0, fw, h), r));
        }
    }
}

/// 进度环（收起状态右翼用）。
public sealed class ProgressRing : Control
{
    public double Fraction { get; set; }
    public double LineWidth { get; set; } = 2.6;

    public override void Render(DrawingContext ctx)
    {
        var size = Math.Min(Bounds.Width, Bounds.Height);
        var r = (size - LineWidth) / 2;
        var c = new Point(Bounds.Width / 2, Bounds.Height / 2);
        ctx.DrawEllipse(null, new Pen(Hue.Track.B(), LineWidth), c, r, r);
        var f = Math.Clamp(Math.Max(0.02, Fraction), 0, 1);
        var brush = new ConicGradientBrush
        {
            Center = RelativePoint.Center,
            Angle = -90,
            GradientStops = { new GradientStop(Hue.Mint, 0), new GradientStop(Hue.Cyan, 0.5), new GradientStop(Hue.Mint, 1) },
        };
        var pen = new Pen(brush, LineWidth, lineCap: PenLineCap.Round);
        if (f >= 0.999) { ctx.DrawEllipse(null, pen, c, r, r); return; }
        var g = new StreamGeometry();
        using (var gc = g.Open())
        {
            double a0 = -Math.PI / 2, a1 = a0 + f * 2 * Math.PI;
            gc.BeginFigure(new Point(c.X + r * Math.Cos(a0), c.Y + r * Math.Sin(a0)), false);
            gc.ArcTo(new Point(c.X + r * Math.Cos(a1), c.Y + r * Math.Sin(a1)), new Size(r, r), 0, f > 0.5, SweepDirection.Clockwise);
            gc.EndFigure(false);
        }
        ctx.DrawGeometry(null, pen, g);
    }
}

/// 一张 GPU 的小方块。
public sealed class GpuCell : Control
{
    public GPUStat Gpu { get; set; } = new();

    public override void Render(DrawingContext ctx)
    {
        var w = Bounds.Width; var h = Bounds.Height;
        ctx.DrawRectangle(Hue.Track.B(), null, new RoundedRect(new Rect(0, 0, w, h), 2.5));
        var u = Gpu.Utilization / 100;
        if (u > 0.01)
        {
            var fh = Math.Max(2, h * u);
            using (ctx.PushClip(new RoundedRect(new Rect(0, 0, w, h), 2.5)))
                ctx.DrawRectangle(Hue.Vertical(Hue.Mint, Hue.Cyan), null, new Rect(0, h - fh, w, fh));
        }
        if (Gpu.MemoryFraction > 0.9) ctx.DrawRectangle(Hue.Amber.B(), null, new RoundedRect(new Rect(0, 0, w, 2), 1));
    }
}

/// 数组进度条：成功（绿）+ 失败（红）+ 运行中（蓝）+ 排队（底色）。
public sealed class ArrayBar : Control
{
    public ArrayInfo Array { get; set; } = new();
    public double BarHeight { get; set; } = 4;

    public ArrayBar() { VerticalAlignment = VerticalAlignment.Center; }

    protected override Size MeasureOverride(Size availableSize) => new(0, BarHeight);

    public override void Render(DrawingContext ctx)
    {
        var w = Bounds.Width; var h = BarHeight;
        var clip = new RoundedRect(new Rect(0, 0, w, h), h / 2);
        ctx.DrawRectangle(Hue.Track.B(), null, clip);
        double total = Math.Max(Array.Total, 1), x = 0;
        using (ctx.PushClip(clip))
        {
            foreach (var (c, n) in new[] { (Hue.Mint, Array.Done), (Hue.Coral, Array.Failed), (Hue.Cyan.WithAlpha(0.55), Array.Running.Count) })
            {
                var sw = n / total * w;
                if (sw <= 0.5) continue;
                sw = Math.Max(sw, 2);
                ctx.DrawRectangle(c.B(), null, new Rect(x, 0, sw, h));
                x += sw + 1;
            }
        }
    }

    /// 悬停说明：进度条每种颜色代表什么。
    public static string Legend(ArrayInfo a) =>
        L($"绿色 完成 {a.Done} · 红色 失败 {a.Failed} · 蓝色 运行中 {a.Running.Count} · 灰色 排队 {a.Pending}",
          $"Green done {a.Done} · Red failed {a.Failed} · Blue running {a.Running.Count} · Gray pending {a.Pending}");
}

/// 让子控件匀速旋转（刷新中）。
public sealed class Spinning : Decorator
{
    readonly RotateTransform _rot = new();
    DispatcherTimer? _timer;

    public Spinning(Control child)
    {
        Child = child;
        child.RenderTransform = _rot;
        child.RenderTransformOrigin = RelativePoint.Center;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (Preview.PreviewRenderer.Active) return;
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(33), DispatcherPriority.Render, (_, _) => _rot.Angle = (_rot.Angle + 12) % 360);
        _timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _timer?.Stop();
        _timer = null;
    }
}

/// 小号的"加载中"圈。
public sealed class MiniSpinner : Control
{
    readonly double _size;
    DispatcherTimer? _timer;
    double _angle;

    public MiniSpinner(double size = 10) { _size = size; Width = size; Height = size; VerticalAlignment = VerticalAlignment.Center; }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (Preview.PreviewRenderer.Active) return;
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(40), DispatcherPriority.Render, (_, _) => { _angle = (_angle + 18) % 360; InvalidateVisual(); });
        _timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _timer?.Stop();
    }

    public override void Render(DrawingContext ctx)
    {
        var r = _size / 2 - 1;
        var c = new Point(_size / 2, _size / 2);
        ctx.DrawEllipse(null, new Pen(Hue.W(0.15).B(), 1.6), c, r, r);
        var a0 = _angle * Math.PI / 180;
        var a1 = a0 + Math.PI * 0.6;
        var g = new StreamGeometry();
        using (var gc = g.Open())
        {
            gc.BeginFigure(new Point(c.X + r * Math.Cos(a0), c.Y + r * Math.Sin(a0)), false);
            gc.ArcTo(new Point(c.X + r * Math.Cos(a1), c.Y + r * Math.Sin(a1)), new Size(r, r), 0, false, SweepDirection.Clockwise);
            gc.EndFigure(false);
        }
        ctx.DrawGeometry(null, new Pen(Hue.W(0.75).B(), 1.6, lineCap: PenLineCap.Round), g);
    }
}
