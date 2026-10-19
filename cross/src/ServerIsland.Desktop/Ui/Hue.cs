using Avalonia;
using Avalonia.Media;
using Avalonia.Media.Immutable;
using ServerIsland.Core;

namespace ServerIsland.Desktop.Ui;

/// 和 Swift 版 Hue.swift 一致的配色；字体用各平台的系统字体（没有 SF Rounded）。
public static class Hue
{
    static Color Rgb(double r, double g, double b, double a = 1) =>
        Color.FromArgb((byte)Math.Round(a * 255), (byte)Math.Round(r * 255), (byte)Math.Round(g * 255), (byte)Math.Round(b * 255));

    public static readonly Color Mint = Rgb(0.35, 0.91, 0.70);
    public static readonly Color Cyan = Rgb(0.36, 0.76, 1.00);
    public static readonly Color Amber = Rgb(1.00, 0.75, 0.30);
    public static readonly Color Coral = Rgb(1.00, 0.43, 0.43);
    public static readonly Color Blue = Rgb(0.45, 0.62, 1.00);
    public static readonly Color Violet = Rgb(0.66, 0.55, 1.00);
    public static readonly Color White = Colors.White;

    public static Color WithAlpha(this Color c, double a) => Color.FromArgb((byte)Math.Round(a * c.A), c.R, c.G, c.B);
    public static Color W(double a) => Rgb(1, 1, 1, a);

    public static readonly Color Text = W(0.94);
    public static readonly Color Secondary = W(0.58);
    public static readonly Color Tertiary = W(0.36);
    public static readonly Color Hairline = W(0.08);
    public static readonly Color Card = W(0.055);
    public static readonly Color Track = W(0.10);

    static readonly Dictionary<Color, IBrush> Cache = [];

    public static IBrush B(this Color c)
    {
        lock (Cache)
        {
            if (!Cache.TryGetValue(c, out var b)) Cache[c] = b = new ImmutableSolidColorBrush(c);
            return b;
        }
    }

    public static IBrush Horizontal(Color a, Color b) => new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, 0.5, RelativeUnit.Relative),
        EndPoint = new RelativePoint(1, 0.5, RelativeUnit.Relative),
        GradientStops = { new GradientStop(a, 0), new GradientStop(b, 1) },
    };

    public static IBrush Vertical(Color top, Color bottom) => new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0.5, 0, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0.5, 1, RelativeUnit.Relative),
        GradientStops = { new GradientStop(top, 0), new GradientStop(bottom, 1) },
    };

    public static IBrush Progress => Horizontal(Mint, Cyan);
    public static IBrush TimeProgress => Horizontal(W(0.55 * 0.7), W(0.85 * 0.7));

    public static Color For(JobState s) => s switch
    {
        JobState.Running or JobState.Completing => Mint,
        JobState.Pending => Amber,
        JobState.Completed => Blue,
        JobState.Failed or JobState.Timeout => Coral,
        _ => Tertiary,
    };

    public static Color For(HostHealth h) => h.Kind switch
    {
        HealthKind.Ok => Mint,
        HealthKind.NeedsLogin => Amber,
        HealthKind.Error => Coral,
        _ => Tertiary,
    };

    /// 资源占用越高颜色越"热"。
    public static Color Load(double fraction) => fraction < 0.6 ? Mint : fraction < 0.7 ? Cyan : fraction < 0.85 ? Amber : Coral;

    /// 界面字体：Windows 用 Segoe UI Variable / 微软雅黑，Linux 用 Noto / Ubuntu，macOS（开发）用苹方。
    public static readonly FontFamily Sans = new(
        "Segoe UI Variable Text, Segoe UI, Microsoft YaHei UI, PingFang SC, Helvetica Neue, Noto Sans CJK SC, Noto Sans SC, Ubuntu, Cantarell, Noto Sans, DejaVu Sans");
    public static readonly FontFamily Mono = new(
        "Cascadia Mono, Consolas, Menlo, SF Mono, JetBrains Mono, DejaVu Sans Mono, Noto Sans Mono, Liberation Mono, monospace");

    /// SwiftUI 的字号在 Windows / Linux 上视觉偏小，统一略放大一点点，布局尺寸不变。
    public const double FontScale = 1.0;
}
