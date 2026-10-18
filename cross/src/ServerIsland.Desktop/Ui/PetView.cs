using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using ServerIsland.Core;

namespace ServerIsland.Desktop.Ui;

/// 刘海里的小宠物：像素小章鱼 "Tako"（与 Swift 版 Pet.swift 的网格、配色、动画完全一致）。
public static class PetSprite
{
    public const int Width = 16, Height = 14;

    static readonly string[] Head =
    [
        "......BBBB......",
        "....BBBBBBBB....",
        "...BHHBBBBBBB...",
        "..BHHBBBBBBBBB..",
        "..BHBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "..SBBBBBBBBBBS..",
    ];
    static readonly string[] LegsA = [".SBB.BB..BB.BBS.", ".BB..BB..BB..BB.", "BB..BB....BB..BB", "B...B......B...B"];
    static readonly string[] LegsB = [".SBB.BB..BB.BBS.", "..BB.BB..BB.BB..", "..B..BB..BB..B..", ".BB...B..B...BB."];
    /// 收拢的腿（开心蹦起来时）
    static readonly string[] LegsTucked = [".SBBBBB..BBBBBS.", "..BB.BB..BB.BB..", "...B.B....B.B...", "................"];

    public static char[][] Frame(PetMood mood, int tick)
    {
        var legs = mood switch
        {
            PetMood.Working => tick % 2 == 0 ? LegsA : LegsB,
            PetMood.Happy => tick % 2 == 0 ? LegsTucked : LegsA,
            _ => LegsA,
        };
        var g = Head.Concat(legs).Select(r => r.ToCharArray()).ToArray();
        void Put(int r, int c, char ch) { if (r >= 0 && r < Height && c >= 0 && c < Width) g[r][c] = ch; }
        // 腮红
        Put(8, 3, 'C'); Put(8, 12, 'C');

        bool blink = mood == PetMood.Idle && tick % 14 == 0;
        switch (mood)
        {
            case PetMood.Happy:
                // ^ ^ 眯眼笑 + 张嘴
                foreach (var c in new[] { 4, 11 }) { Put(6, c, 'E'); Put(7, c - 1, 'E'); Put(7, c + 1, 'E'); }
                Put(8, 7, 'M'); Put(8, 8, 'M'); Put(9, 7, 'C'); Put(9, 8, 'C');
                break;
            case PetMood.Sad:
                // x x 晕了 + 撇嘴 + 一滴汗
                foreach (var c in new[] { 4, 11 })
                {
                    Put(5, c - 1, 'E'); Put(5, c + 1, 'E'); Put(6, c, 'E'); Put(7, c - 1, 'E'); Put(7, c + 1, 'E');
                }
                Put(9, 7, 'M'); Put(9, 8, 'M'); Put(8, 6, 'M'); Put(8, 9, 'M');
                Put(2, 13, 'R'); Put(3, 13, 'R'); Put(3, 14, 'R');
                break;
            case PetMood.Waiting:
                // 半闭的困眼
                foreach (var c in new[] { 4, 10 }) { Put(6, c, 'S'); Put(6, c + 1, 'S'); Put(7, c, 'E'); Put(7, c + 1, 'E'); }
                break;
            default:
                if (blink) foreach (var c in new[] { 4, 10 }) { Put(7, c, 'E'); Put(7, c + 1, 'E'); }
                else foreach (var c in new[] { 4, 10 }) { Put(6, c, 'W'); Put(6, c + 1, 'E'); Put(7, c, 'E'); Put(7, c + 1, 'E'); }
                if (mood == PetMood.Worried) { Put(2, 13, 'R'); Put(3, 13, 'R'); Put(3, 14, 'R'); }
                Put(8, 7, 'M'); Put(8, 8, 'M');
                break;
        }
        return g;
    }

    static Color Rgb(double r, double g, double b) => Color.FromRgb((byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

    public static Color? ColorOf(char ch, PetMood mood)
    {
        bool sad = mood == PetMood.Sad;
        return ch switch
        {
            'B' => sad ? Rgb(1.00, 0.55, 0.55) : Rgb(0.36, 0.90, 0.71),
            'S' => sad ? Rgb(0.80, 0.33, 0.36) : Rgb(0.18, 0.68, 0.53),
            'H' => sad ? Rgb(1.00, 0.80, 0.80) : Rgb(0.74, 0.98, 0.87),
            'E' or 'M' => Rgb(0.04, 0.06, 0.12),
            'W' => Colors.White,
            'C' => Rgb(1.00, 0.56, 0.67),
            'R' => Rgb(0.49, 0.78, 1.00),
            _ => null,
        };
    }

    /// 动画帧率很低（2–3 fps），几乎不占资源。
    public static double Interval(PetMood mood) => mood switch
    {
        PetMood.Working => 0.32,
        PetMood.Happy => 0.26,
        PetMood.Waiting => 0.9,
        _ => 0.45,
    };
}

/// 像素宠物视图。Animated 为 false 时渲染静态帧（预览用）。
public sealed class PetView : Control
{
    public PetMood Mood { get; set; }
    readonly double _size;
    readonly bool _animated;
    int _tick = 1;
    DispatcherTimer? _timer;

    public PetView(PetMood mood, double size = 20, bool animated = true)
    {
        Mood = mood;
        _size = size;
        _animated = animated && !Preview.PreviewRenderer.Active;
        double px = size / PetSprite.Height;
        Width = px * PetSprite.Width;
        Height = size + px * 2;
        IsHitTestVisible = false;
        ClipToBounds = false;
    }

    protected override void OnAttachedToVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnAttachedToVisualTree(e);
        if (!_animated) return;
        var interval = PetSprite.Interval(Mood);
        _timer = new DispatcherTimer(TimeSpan.FromSeconds(interval), DispatcherPriority.Background, (_, _) =>
        {
            _tick = (int)(DateTime.Now.TimeOfDay.TotalSeconds / interval);
            InvalidateVisual();
        });
        _timer.Start();
    }

    protected override void OnDetachedFromVisualTree(VisualTreeAttachmentEventArgs e)
    {
        base.OnDetachedFromVisualTree(e);
        _timer?.Stop();
        _timer = null;
    }

    public override void Render(DrawingContext ctx)
    {
        double px = _size / PetSprite.Height;
        var grid = PetSprite.Frame(Mood, _tick);
        double bob = Mood switch
        {
            PetMood.Working => _tick % 2 == 0 ? 0 : -px,
            PetMood.Happy => _tick % 2 == 0 ? -px * 2 : 0,
            PetMood.Worried => _tick % 6 == 0 ? -px : 0,
            _ => 0,
        };
        // 柔光（和 SwiftUI 版的 shadow 对应）
        var glow = (Mood == PetMood.Sad ? Hue.Coral : Hue.Mint).WithAlpha(0.22);
        var center = new Point(Bounds.Width / 2, px * 2 + _size / 2 + bob);
        var radial = new RadialGradientBrush
        {
            GradientStops = { new GradientStop(glow, 0), new GradientStop(glow.WithAlpha(0), 1) },
        };
        ctx.DrawEllipse(radial, null, center, Bounds.Width * 0.62, _size * 0.62);
        for (int r = 0; r < grid.Length; r++)
            for (int c = 0; c < grid[r].Length; c++)
                if (PetSprite.ColorOf(grid[r][c], Mood) is { } color)
                    ctx.DrawRectangle(color.B(), null, new Rect(c * px, r * px + bob + px * 2, px + 0.5, px + 0.5));
        if (Mood == PetMood.Waiting)
        {
            var z = new FormattedText(_tick % 2 == 0 ? "z" : "Z", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                new Typeface(Hue.Sans, FontStyle.Normal, FontWeight.Black), Math.Max(7, _size * 0.36), Hue.Amber.WithAlpha(0.9).B());
            ctx.DrawText(z, new Point(Bounds.Width - z.Width + px * 2, _tick % 2 == 0 ? 0 : -px));
        }
    }
}
