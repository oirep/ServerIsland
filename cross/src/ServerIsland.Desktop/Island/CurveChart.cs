using Avalonia;
using Avalonia.Controls;
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
        var legend = H(10, T(curve.Title, 10.5, FontWeight.SemiBold, Hue.Secondary));
        for (int i = 0; i < curve.SeriesList.Count; i++)
        {
            var s = curve.SeriesList[i];
            var item = H(4, new Border { Width = 9, Height = 2.5, CornerRadius = new CornerRadius(2), Background = Colors[i % Colors.Length].B() },
                         T(s.Name, 9.5, color: Hue.Tertiary));
            if (s.Points.Count > 0) item.Children.Add(T(AppProgress.Sci(s.Points[^1].Y), 9.5, color: Hue.Secondary));
            legend.Children.Add(item);
        }
        if (curve.Threshold is { } t)
            legend.Children.Add(H(4, new Border { Width = 9, Height = 1.5, CornerRadius = new CornerRadius(1), Background = Hue.Amber.WithAlpha(0.8).B() },
                                  T(L("目标", "target"), 9.5, color: Hue.Tertiary), T(AppProgress.Sci(t), 9.5, color: Hue.Secondary)));
        var xText = !compact && curve.SeriesList.FirstOrDefault()?.Points is { Count: > 0 } pts ? curve.XLabel + " " + AppProgress.Compact(pts[^1].X) : "";
        var top = Row(6, Fill(legend), T(xText, 9.5, color: Hue.Tertiary));

        var plot = new Plot(curve);
        var axis = new Grid { Width = 46, RowDefinitions = new RowDefinitions("Auto,*,Auto") };
        var maxT = T(plot.AxisLabel(plot.Bounds2.Bottom), 8.5, color: Hue.Tertiary, mono: true).HA(HorizontalAlignment.Right);
        var minT = T(plot.AxisLabel(plot.Bounds2.Top), 8.5, color: Hue.Tertiary, mono: true).HA(HorizontalAlignment.Right);
        Grid.SetRow(minT, 2);
        axis.Children.Add(maxT);
        axis.Children.Add(minT);
        var body = new Grid { ColumnDefinitions = new ColumnDefinitions("46,6,*") };
        body.Children.Add(axis);
        Grid.SetColumn(plot, 2);
        body.Children.Add(plot);

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
                if (curve.Threshold is { } t) ys.Add(Ty(t));
                double y0 = ys.Min(), y1 = ys.Max();
                if (y1 - y0 < 1e-9) { y0 -= 0.5; y1 += 0.5; }
                return new Rect(x0, y0, Math.Max(x1 - x0, 1e-9), y1 - y0);
            }
        }

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
            if (curve.Threshold is { } t)
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
                ctx.DrawGeometry(null, new Pen(Colors[i % Colors.Length].B(), 1.3, lineJoin: PenLineJoin.Round), g);
            }
        }
    }
}
