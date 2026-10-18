using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Shapes;
using Avalonia.Layout;
using Avalonia.Media;
using ServerIsland.Core;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Desktop.Ui.Kit;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop.Island;

/// 详情页的小曲线（NEP loss / VASP 能量和最大力），与 Swift 版 CurveChart.swift 一致。
public static class CurveChart
{
    public static readonly Color[] Colors = [Hue.Mint, Hue.Cyan, Hue.Amber, Hue.Violet];

    /// compact：两张图并排时省掉右上角的"离子步 N"，标题行放得下。
    public static Control Build(AppCurve curve, bool compact = false)
    {
        var legend = H(8, T(curve.Title, 10.5, FontWeight.SemiBold, Hue.Secondary));
        for (int i = 0; i < curve.SeriesList.Count; i++)
        {
            var s = curve.SeriesList[i];
            Control swatch = s.Markers
                ? new Ellipse { Width = 5, Height = 5, Fill = Colors[i % Colors.Length].B(), VerticalAlignment = VerticalAlignment.Center }
                : new Border { Width = 9, Height = 2.5, CornerRadius = new CornerRadius(2), Background = Colors[i % Colors.Length].WithAlpha(s.Faint ? 0.5 : 1).B() };
            var item = H(4, swatch, T(s.Name, 9.5, color: Hue.Tertiary));
            if (!s.Markers && s.Points.Count > 0) item.Children.Add(T(AppProgress.Sci(s.Points[^1].Y), 9.5, color: Hue.Secondary));
            legend.Children.Add(item);
        }
        if (curve.Bars.Count > 0)
        {
            var bar = H(4, new Border { Width = 6, Height = 8, CornerRadius = new CornerRadius(1), Background = Hue.Mint.WithAlpha(0.5).B(), VerticalAlignment = VerticalAlignment.Center },
                        T(curve.BarsLabel, 9.5, color: Hue.Tertiary), T(AppProgress.Sci(curve.Bars.Max(b => b.Y)), 9.5, color: Hue.Secondary));
            if (curve.Threshold is { } bt)
            {
                bar.Children.Add(new Border { Width = 9, Height = 1.5, CornerRadius = new CornerRadius(1), Background = Hue.Amber.WithAlpha(0.8).B(), VerticalAlignment = VerticalAlignment.Center });
                bar.Children.Add(T(AppProgress.Sci(bt), 9.5, color: Hue.Secondary));
            }
            legend.Children.Add(bar);
        }
        // 图例放不下时裁掉，绝不和右边的文字叠在一起
        var legendBox = new Border { Child = legend, ClipToBounds = true };
        var xText = !compact && curve.SeriesList.FirstOrDefault()?.Points is { Count: > 0 } pts ? curve.XLabel + " " + AppProgress.Compact(pts[^1].X) : "";
        var top = Row(6, Fill(legendBox), T(xText, 9.5, color: Hue.Tertiary));

        var plot = new Plot(curve);
        var axis = new Grid { Width = 46, RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var (lo, hi) = plot.LabelRange;
        var maxT = T(plot.AxisLabel(hi), 8.5, color: Hue.Tertiary, mono: true).HA(HorizontalAlignment.Right);
        var minT = T(plot.AxisLabel(lo), 8.5, color: Hue.Tertiary, mono: true).HA(HorizontalAlignment.Right);
        Grid.SetRow(minT, 2);
        axis.Children.Add(maxT);
        axis.Children.Add(minT);
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("46,6,*") };
        body.Children.Add(axis);
        Grid.SetColumn(plot, 2);
        body.Children.Add(plot);
        // 收敛判据放在图的右上角（结构优化的力从左上往右下降，右上角通常是空的），图例那一行放不下。
        var label = curve.Note ?? (curve.Bars.Count > 0 ? null : curve.Threshold is { } th ? L($"按力收敛 < {AppProgress.Sci(th)} eV/Å", $"force criterion < {AppProgress.Sci(th)} eV/Å") : null);
        if (label != null)
        {
            var tag = H(4);
            if (curve.Threshold != null) tag.Children.Add(new Border { Width = 9, Height = 1.5, CornerRadius = new CornerRadius(1), Background = Hue.Amber.WithAlpha(0.8).B(), VerticalAlignment = VerticalAlignment.Center });
            tag.Children.Add(T(label, 9, color: Hue.Tertiary));
            var corner = new Border
            {
                Child = tag, Background = Hue.Card.WithAlpha(0.9).B(), CornerRadius = new CornerRadius(4), Padding = new Thickness(5, 1.5),
                HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top,
            };
            ToolTip.SetTip(corner, curve.Bars.Count > 0
                ? L("能垒 = 最高的像点 − 初态（00），和 VTST 的 nebef.pl 一样用 energy(sigma→0)。柱子是每个中间像点的最大力（VTST），虚线是 |EDIFFG|：所有柱子都低于虚线时 NEB 收敛。",
                    "Barrier = highest image − initial state (00), using energy(sigma→0) like VTST's nebef.pl. Bars are each image's max force (VTST); the dashed line is |EDIFFG| — NEB has converged when every bar is below it.")
                : curve.Note != null
                ? L("这次结构优化按能量收敛（EDIFFG ≥ 0 或没写，VASP 默认 0.001），最大力不是停止条件，所以没有目标线。",
                    "This relaxation stops on energy (EDIFFG ≥ 0 or unset; VASP's default is 0.001), so the max force isn't the stopping rule and there's no target line.")
                : L("EDIFFG < 0：所有原子的受力都小于这个值时优化结束（虚线）。", "EDIFFG < 0: the relaxation ends when every force is below this value (dashed line)."));
            Grid.SetColumn(corner, 2);
            body.Children.Add(corner);
        }

        var g = new Grid { RowDefinitions = new RowDefinitions("Auto,5,*") };
        g.Children.Add(top);
        Grid.SetRow(body, 2);
        g.Children.Add(body);
        return RoundedCard(g, 12, Hue.Card, 10);
    }

    sealed class Plot(AppCurve curve) : Control
    {
        double Ty(double y) => curve.LogY ? Math.Log10(Math.Max(y, 1e-12)) : y;

        /// 所有曲线共用的范围（已经换算到对数坐标时是指数）。Top = 最小值，Bottom = 最大值。
        public Rect Bounds2
        {
            get
            {
                var pts = curve.SeriesList.SelectMany(s => s.Points).ToList();
                if (pts.Count == 0) return new Rect(0, 0, 1, 1);
                double x0 = pts.Min(p => p.X), x1 = pts.Max(p => p.X);
                var ys = pts.Select(p => Ty(p.Y)).ToList();
                // 有柱子时 Threshold 属于柱子的纵轴，不算在内
                if (curve.Bars.Count == 0 && curve.Threshold is { } t) ys.Add(Ty(t));
                double y0 = ys.Min(), y1 = ys.Max();
                if (y1 - y0 < 1e-9) { y0 -= 0.5; y1 += 0.5; }
                // 带圆点的曲线（NEB）上下留一点空，最高点的圆点不被裁掉
                if (curve.SeriesList.Any(s => s.Markers)) { var pad = (y1 - y0) * 0.1; y0 -= pad; y1 += pad; }
                return new Rect(x0, y0, Math.Max(x1 - x0, 1e-9), y1 - y0);
            }
        }

        /// 纵轴上标的两个数：一般是上下边界；带圆点的曲线（NEB）留了空白，标真实的最高 / 最低值。
        public (double Lo, double Hi) LabelRange
        {
            get
            {
                var b = Bounds2;
                if (!curve.SeriesList.Any(s => s.Markers)) return (b.Top, b.Bottom);
                var ys = curve.SeriesList.SelectMany(s => s.Points).Select(p => Ty(p.Y)).ToList();
                return ys.Count == 0 ? (b.Top, b.Bottom) : (ys.Min(), ys.Max());
            }
        }

        /// 柱子的纵轴：0 到（最大的柱子和目标值里大的那个）再留一点空。
        double BarScale => Math.Max(Math.Max(curve.Bars.Count > 0 ? curve.Bars.Max(p => p.Y) : 0, curve.Threshold ?? 0), 1e-12) * 1.15;

        public string AxisLabel(double v)
        {
            if (curve.LogY) return AppProgress.Sci(Math.Pow(10, v));
            var a = Math.Abs(v);
            if (a >= 100) return Text.Fmt(v, "0.0");
            if (a >= 1) return Text.Fmt(v, "0.00");
            return AppProgress.Sci(v);
        }

        public override void Render(DrawingContext ctx)
        {
            var size = Bounds.Size;
            var grid = new Pen(Hue.W(0.06).B(), 0.5);
            for (int k = 0; k <= 2; k++)
            {
                var y = size.Height * k / 2;
                ctx.DrawLine(grid, new Point(0, y), new Point(size.Width, y));
            }
            var b = Bounds2;
            // NEB：每个中间像点的力（柱子，自己的纵轴，只占下半部分），EDIFFG 虚线画在柱子的纵轴上并在右端标出
            if (curve.Bars.Count > 0)
            {
                double scale = BarScale, area = size.Height * 0.5;
                double w = Math.Min(14, size.Width / Math.Max(curve.SeriesList.FirstOrDefault()?.Points.Count ?? 2, 2) * 0.35);
                foreach (var (bx, by) in curve.Bars)
                {
                    var x = (bx - b.X) / b.Width * size.Width;
                    var h = Math.Max(1, by / scale * area);
                    bool over = curve.Threshold is { } th && by > th;
                    ctx.DrawRectangle((over ? Hue.Amber : Hue.Mint).WithAlpha(0.32).B(), null, new Rect(x - w / 2, size.Height - h, w, h), 1.5, 1.5);
                }
                if (curve.Threshold is { } t2)
                {
                    var y = size.Height - t2 / scale * area;
                    ctx.DrawLine(new Pen(Hue.Amber.WithAlpha(0.75).B(), 0.9, new DashStyle([3, 3], 0)), new Point(0, y), new Point(size.Width - 40, y));
                    var ft = new FormattedText("EDIFFG", System.Globalization.CultureInfo.InvariantCulture, FlowDirection.LeftToRight,
                        new Typeface(Hue.Sans, FontStyle.Normal, FontWeight.SemiBold), 8, Hue.Amber.WithAlpha(0.85).B());
                    ctx.DrawText(ft, new Point(size.Width - 37, y - ft.Height / 2));
                }
            }
            if (curve.Bars.Count == 0 && curve.Threshold is { } t)
            {
                var ty = size.Height - (Ty(t) - b.Y) / b.Height * size.Height;
                ctx.DrawLine(new Pen(Hue.Amber.WithAlpha(0.75).B(), 0.9, new DashStyle([3, 3], 0)), new Point(0, ty), new Point(size.Width, ty));
            }
            for (int i = 0; i < curve.SeriesList.Count; i++)
            {
                var pts = curve.SeriesList[i].Points;
                if (pts.Count < 2) continue;
                var g = new StreamGeometry();
                using (var gc = g.Open())
                {
                    for (int j = 0; j < pts.Count; j++)
                    {
                        var x = (pts[j].X - b.X) / b.Width * size.Width;
                        var y = size.Height - (Ty(pts[j].Y) - b.Y) / b.Height * size.Height;
                        if (j == 0) gc.BeginFigure(new Point(x, y), false);
                        else gc.LineTo(new Point(x, y));
                    }
                    gc.EndFigure(false);
                }
                var faint = curve.SeriesList[i].Faint;
                ctx.DrawGeometry(null, new Pen(Colors[i % Colors.Length].WithAlpha(faint ? 0.45 : 1).B(), faint ? 1 : 1.3,
                    faint ? new DashStyle([2, 2], 0) : null, lineJoin: PenLineJoin.Round), g);
                if (curve.SeriesList[i].Markers)
                    foreach (var (px, py) in pts)
                        ctx.DrawEllipse(Colors[i % Colors.Length].B(), null,
                            new Point((px - b.X) / b.Width * size.Width, size.Height - (Ty(py) - b.Y) / b.Height * size.Height), 2.5, 2.5);
            }
        }
    }
}
