using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;
using ServerIsland.Core;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop.Settings;

/// 设置窗口的配色（跟随系统浅色 / 深色）。
public sealed record Palette(Color Bg, Color Sidebar, Color Card, Color Text, Color Secondary, Color Separator, Color Selection, Color Field)
{
    public static Palette For(ThemeVariant v) => v == ThemeVariant.Dark
        ? new(Color.Parse("#1E1E20"), Color.Parse("#262628"), Color.Parse("#2C2C2E"), Color.Parse("#F2F2F7"), Color.Parse("#98989F"),
              Color.Parse("#3A3A3C"), Color.Parse("#2E5E4E"), Color.Parse("#1C1C1E"))
        : new(Color.Parse("#F2F2F5"), Color.Parse("#E9E9EE"), Color.Parse("#FFFFFF"), Color.Parse("#1C1C1E"), Color.Parse("#6E6E73"),
              Color.Parse("#E3E3E8"), Color.Parse("#CDEEE2"), Color.Parse("#FFFFFF"));
}

/// 设置页里常用的小部件：分组、行、ⓘ 说明、开关、下拉框……
public sealed class SettingsKit(Palette p)
{
    public Palette P => p;

    public TextBlock Text(string s, double size = 13, FontWeight w = FontWeight.Normal, Color? c = null, bool wrap = false, bool mono = false) => new()
    {
        Text = s, FontSize = size, FontWeight = w, Foreground = (c ?? p.Text).B(),
        TextWrapping = wrap ? TextWrapping.Wrap : TextWrapping.NoWrap,
        TextTrimming = wrap ? TextTrimming.None : TextTrimming.CharacterEllipsis,
        FontFamily = mono ? Hue.Mono : Hue.Sans,
        VerticalAlignment = VerticalAlignment.Center,
    };

    public TextBlock Caption(string s) => Text(s, 11.5, c: p.Secondary, wrap: true);

    /// 内容为空时隐藏的说明文字（用于异步结果、错误提示）。
    public TextBlock Status(Color? c = null)
    {
        var t = Text("", 11.5, c: c ?? p.Secondary, wrap: true);
        t.IsVisible = false;
        t.PropertyChanged += (_, e) => { if (e.Property == TextBlock.TextProperty) t.IsVisible = !string.IsNullOrEmpty(t.Text); };
        return t;
    }

    /// 设置项标签：名称后面跟一个 ⓘ，悬停显示解释（代替括号里的说明）。
    public Control Label(string title, string? help = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5, VerticalAlignment = VerticalAlignment.Center };
        if (title.Length > 0) row.Children.Add(Text(title));
        if (!string.IsNullOrEmpty(help))
        {
            var i = new Border
            {
                Width = 15, Height = 15, Background = Brushes.Transparent,
                Child = new Icon("question", 13, p.Secondary.B(), 1.8) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
            };
            ToolTip.SetTip(i, help);
            ToolTip.SetShowDelay(i, 150);
            row.Children.Add(i);
        }
        return row;
    }

    public Control IconSquare(string icon, Color tint, double size = 22) => new Border
    {
        Width = size, Height = size, CornerRadius = new CornerRadius(size * 0.27),
        Background = Hue.Vertical(Lighten(tint, 0.18), tint),
        Child = new Icon(icon, size * 0.6, Brushes.White, 2.4) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        VerticalAlignment = VerticalAlignment.Center,
    };

    static Color Lighten(Color c, double f) => Color.FromRgb((byte)(c.R + (255 - c.R) * f), (byte)(c.G + (255 - c.G) * f), (byte)(c.B + (255 - c.B) * f));

    /// 分组：彩色图标 + 标题，下面是一张圆角卡片，行与行之间有分隔线。
    public Control Section(string title, string icon, Color tint, IEnumerable<Control?> rows, string? footer = null)
    {
        var col = new StackPanel { Spacing = 8, Margin = new Thickness(0, 0, 0, 22) };
        if (title.Length > 0)
        {
            col.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(2, 0, 0, 0),
                Children = { IconSquare(icon, tint), Text(title, 13.5, FontWeight.SemiBold) },
            });
        }
        var card = new StackPanel();
        bool first = true;
        foreach (var r in rows)
        {
            if (r == null) continue;
            if (!first)
            {
                var sep = new Border { Height = 1, Background = p.Separator.B(), Margin = new Thickness(14, 0, 0, 0), IsVisible = r.IsVisible };
                r.PropertyChanged += (_, e) => { if (e.Property == Visual.IsVisibleProperty) sep.IsVisible = r.IsVisible; };
                card.Children.Add(sep);
            }
            first = false;
            r.Margin = new Thickness(14, 9, 14, 9);
            card.Children.Add(r);
        }
        col.Children.Add(new Border
        {
            Background = p.Card.B(), CornerRadius = new CornerRadius(10),
            BorderBrush = p.Separator.B(), BorderThickness = new Thickness(0.5),
            Child = card,
        });
        if (footer != null) col.Children.Add(Caption(footer).Margin2(4, 0, 4, 0));
        return col;
    }

    /// 一行：左边标签，右边控件。
    public Control Row(Control label, Control control)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto"), MinHeight = 28 };
        g.Children.Add(label);
        control.HorizontalAlignment = HorizontalAlignment.Right;
        control.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }

    public Control Row(string title, string? help, Control control) => Row(Label(title, help), control);

    /// 标签在左，控件占满右边剩余宽度（文本框）。
    public Control WideRow(string title, string? help, Control control, double labelWidth = 120)
    {
        var g = new Grid { ColumnDefinitions = new ColumnDefinitions($"{labelWidth},*") };
        g.Children.Add(Label(title, help));
        Grid.SetColumn(control, 1);
        g.Children.Add(control);
        return g;
    }

    public ToggleSwitch Toggle(bool value, Action<bool> set)
    {
        var t = new ToggleSwitch { IsChecked = value, OnContent = null, OffContent = null, MinWidth = 0, Padding = new Thickness(0), Margin = new Thickness(0) };
        t.IsCheckedChanged += (_, _) => set(t.IsChecked == true);
        return t;
    }

    public Control ToggleRow(string title, string? help, bool value, Action<bool> set) => Row(title, help, Toggle(value, set));

    public ComboBox Combo<T>(IEnumerable<(T Value, string Label)> items, T current, Action<T> set, double minWidth = 180)
    {
        var list = items.ToList();
        var c = new ComboBox { MinWidth = minWidth };
        foreach (var (_, label) in list) c.Items.Add(label);
        c.SelectedIndex = Math.Max(0, list.FindIndex(i => EqualityComparer<T>.Default.Equals(i.Value, current)));
        c.SelectionChanged += (_, _) => { if (c.SelectedIndex >= 0 && c.SelectedIndex < list.Count) set(list[c.SelectedIndex].Value); };
        return c;
    }

    public TextBox Field(string value, Action<string> set, string? watermark = null, bool mono = false, bool multiline = false)
    {
        var t = new TextBox
        {
            Text = value, Watermark = watermark,
            FontFamily = mono ? Hue.Mono : Hue.Sans, FontSize = mono ? 12 : 13,
            AcceptsReturn = multiline, TextWrapping = multiline ? TextWrapping.Wrap : TextWrapping.NoWrap,
            MinHeight = multiline ? 64 : 0,
        };
        t.TextChanged += (_, _) => set(t.Text ?? "");
        return t;
    }

    public Button Button(string title, Action action, bool accent = false, bool danger = false)
    {
        var b = new Button { Content = title, VerticalAlignment = VerticalAlignment.Center };
        if (accent) b.Classes.Add("accent");
        if (danger) b.Foreground = Color.Parse("#E5484D").B();
        b.Click += (_, _) => action();
        return b;
    }

    public Control Link(string title, Action action)
    {
        var t = Text(title, 12, c: Color.Parse("#2EAD87"));
        t.Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand);
        t.PointerReleased += (_, _) => action();
        return t;
    }

    /// 分段选择（SwiftUI 的 .segmented）。
    public Control Segmented<T>(IEnumerable<(T Value, string Label)> items, T current, Action<T> set)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        var list = items.ToList();
        var buttons = new List<ToggleButton2>();
        for (int i = 0; i < list.Count; i++)
        {
            var (v, label) = list[i];
            var b = new ToggleButton2(label, EqualityComparer<T>.Default.Equals(v, current), i == 0, i == list.Count - 1);
            buttons.Add(b);
            b.Click += (_, _) =>
            {
                foreach (var o in buttons) o.Selected = o == b;
                set(v);
            };
            row.Children.Add(b);
        }
        return row;
    }

    public sealed class ToggleButton2 : Avalonia.Controls.Button
    {
        bool _selected;
        public bool Selected { get => _selected; set { _selected = value; Classes.Set("accent", value); } }
        protected override Type StyleKeyOverride => typeof(Avalonia.Controls.Button);

        public ToggleButton2(string label, bool selected, bool first, bool last)
        {
            Content = label;
            MinWidth = 110;
            HorizontalContentAlignment = HorizontalAlignment.Center;
            CornerRadius = new CornerRadius(first ? 6 : 0, last ? 6 : 0, last ? 6 : 0, first ? 6 : 0);
            Selected = selected;
        }
    }
}

public static class SettingsExt
{
    public static T Margin2<T>(this T c, double l, double t, double r, double b) where T : Control { c.Margin = new Thickness(l, t, r, b); return c; }
}
