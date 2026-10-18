using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace ServerIsland.Desktop.Ui;

/// 横向排列，宽度不够时只压缩其中一个子控件（通常是名称文字，会显示省略号），其余保持原宽度——和 SwiftUI 的 HStack 一样。
public sealed class ShrinkRow : Panel
{
    public double Spacing { get; set; }
    /// 被压缩的子控件下标。
    public int ShrinkIndex { get; set; }

    public ShrinkRow(double spacing, int shrinkIndex, params Control?[] children)
    {
        Spacing = spacing;
        ShrinkIndex = shrinkIndex;
        VerticalAlignment = VerticalAlignment.Center;
        foreach (var c in children) if (c != null) Children.Add(c);
    }

    protected override Size MeasureOverride(Size available)
    {
        double fixedW = 0, h = 0;
        int visible = 0;
        for (int i = 0; i < Children.Count; i++)
        {
            var c = Children[i];
            if (!c.IsVisible) continue;
            visible++;
            if (i == ShrinkIndex) continue;
            c.Measure(new Size(double.PositiveInfinity, available.Height));
            fixedW += c.DesiredSize.Width;
            h = Math.Max(h, c.DesiredSize.Height);
        }
        double spacing = Math.Max(0, visible - 1) * Spacing;
        if (ShrinkIndex < Children.Count && Children[ShrinkIndex].IsVisible)
        {
            var rest = Math.Max(0, available.Width - fixedW - spacing);
            Children[ShrinkIndex].Measure(new Size(rest, available.Height));
            fixedW += Children[ShrinkIndex].DesiredSize.Width;
            h = Math.Max(h, Children[ShrinkIndex].DesiredSize.Height);
        }
        return new Size(Math.Min(fixedW + spacing, double.IsInfinity(available.Width) ? fixedW + spacing : available.Width), h);
    }

    protected override Size ArrangeOverride(Size final)
    {
        double x = 0;
        foreach (var c in Children)
        {
            if (!c.IsVisible) continue;
            double w = c.DesiredSize.Width;
            double y = c.VerticalAlignment switch
            {
                VerticalAlignment.Top => 0,
                VerticalAlignment.Bottom => final.Height - c.DesiredSize.Height,
                VerticalAlignment.Stretch => 0,
                _ => (final.Height - c.DesiredSize.Height) / 2,
            };
            double hh = c.VerticalAlignment == VerticalAlignment.Stretch ? final.Height : c.DesiredSize.Height;
            c.Arrange(new Rect(x, y, Math.Max(0, Math.Min(w, final.Width - x)), hh));
            x += w + Spacing;
        }
        return final;
    }
}
