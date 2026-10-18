using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Threading;
using ServerIsland.Core;
using ServerIsland.Core.Ssh;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop.Settings;

public enum SettingsPageKind { General, Rules, Host }

/// 设置窗口：左侧栏是"通用""进度识别"和服务器列表，右侧是详情。（与 Swift 版 SettingsView.swift 对应）
public sealed class SettingsWindow : Window
{
    readonly ConfigStore _store;
    readonly MonitorEngine _engine;
    readonly ILoginPrompter _prompter;
    SettingsPageKind _kind = SettingsPageKind.General;
    Guid _hostID;
    readonly Grid _root = new() { ColumnDefinitions = new ColumnDefinitions("236,*") };
    readonly Border _sidebar = new();
    readonly ScrollViewer _scroll = new() { HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
    Palette _p = Palette.For(ThemeVariant.Light);
    Action? _pageEngineUpdate;
    string _sidebarKey = "";
    AppLanguage _lang;

    public SettingsWindow(ConfigStore store, MonitorEngine engine, ILoginPrompter prompter, SettingsPageKind initial = SettingsPageKind.General)
    {
        _store = store;
        _engine = engine;
        _prompter = prompter;
        _kind = initial;
        Title = "ServerIsland";
        Width = 900;
        Height = 660;
        MinWidth = 760;
        MinHeight = 520;
        Icon = App.WindowIcon;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        _lang = store.Settings.Language;
        Grid.SetColumn(_scroll, 1);
        _root.Children.Add(_sidebar);
        _root.Children.Add(_scroll);
        Content = _root;
        ActualThemeVariantChanged += (_, _) => RebuildAll();
        _store.Changed += OnStoreChanged;
        Closed += (_, _) => _store.Changed -= OnStoreChanged;
        RebuildAll();
    }

    public void Select(SettingsPageKind kind, Guid host = default)
    {
        _kind = kind;
        _hostID = host;
        RebuildAll();
    }

    void OnStoreChanged()
    {
        // 切换语言后整页重绘；其它改动只更新侧栏（避免打字时重建输入框）。
        if (_store.Settings.Language != _lang)
        {
            _lang = _store.Settings.Language;
            Dispatcher.UIThread.Post(RebuildAll);
            return;
        }
        Dispatcher.UIThread.Post(BuildSidebar, DispatcherPriority.Background);
    }

    public void EngineChanged()
    {
        BuildSidebar();
        _pageEngineUpdate?.Invoke();
    }

    void RebuildAll()
    {
        _p = Palette.For(ActualThemeVariant);
        Background = _p.Bg.B();
        _sidebarKey = "";
        BuildSidebar();
        BuildPage();
    }

    /// 重建当前页面，保留滚动位置（切换会改变其它项可见性的开关时用）。
    public void RefreshPage()
    {
        var offset = _scroll.Offset;
        BuildPage();
        Dispatcher.UIThread.Post(() => _scroll.Offset = offset, DispatcherPriority.Loaded);
    }

    void BuildSidebar()
    {
        var hosts = _store.Settings.Hosts;
        var key = $"{_kind}|{_hostID}|{_store.Settings.ProgressRules.Count}|" + string.Join(";", hosts.Select(h =>
        {
            var s = _engine.Snapshots.GetValueOrDefault(h.Id);
            return $"{h.Id}|{h.DisplayName}|{h.Enabled}|{h.Paused}|{h.Muted}|{h.Kind}|{s?.Health}|{s?.RunningCount}|{s?.PendingCount}";
        }));
        if (key == _sidebarKey) return;
        _sidebarKey = key;
        var k = new SettingsKit(_p);
        var list = new StackPanel { Spacing = 2, Margin = new Thickness(10, 14, 10, 10) };
        list.Children.Add(SidebarRow(k, L("通用", "General"), L("轮询、提醒、提示音", "Refresh, alerts, sounds"), "gear", Color.Parse("#8E8E93"),
            _kind == SettingsPageKind.General, () => Select(SettingsPageKind.General)));
        var rules = _store.Settings.ProgressRules.Count;
        list.Children.Add(SidebarRow(k, L("进度识别", "Progress Detection"),
            rules == 0 ? L("内置软件、自定义规则", "Built-in apps, custom rules") : L($"{rules} 条自定义规则", $"{rules} custom rules"),
            "wand", Color.Parse("#5856D6"), _kind == SettingsPageKind.Rules, () => Select(SettingsPageKind.Rules)));
        list.Children.Add(k.Text(L("服务器", "Servers"), 11.5, FontWeight.SemiBold, _p.Secondary).Margin2(10, 14, 0, 4));
        foreach (var h in hosts)
        {
            var host = h;
            var snap = _engine.Snapshots.GetValueOrDefault(h.Id);
            list.Children.Add(HostRow(k, host, snap, _kind == SettingsPageKind.Host && _hostID == h.Id, () => Select(SettingsPageKind.Host, host.Id)));
        }
        var add = new Button
        {
            Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, Children = { new Icon("plus", 13, Brushes.White, 2.8), new TextBlock { Text = L("添加服务器", "Add Server"), Foreground = Brushes.White } } },
            HorizontalAlignment = HorizontalAlignment.Stretch, HorizontalContentAlignment = HorizontalAlignment.Center,
            Background = Color.Parse("#2EAD87").B(), Margin = new Thickness(12), Padding = new Thickness(0, 9),
        };
        add.Click += async (_, _) =>
        {
            var added = await AddHostDialog.Show(this, _store.Settings.Hosts);
            if (added.Count == 0) return;
            _store.Settings.Hosts.AddRange(added);
            _store.Touch();
            Select(SettingsPageKind.Host, added[0].Id);
        };
        var dock = new DockPanel();
        DockPanel.SetDock(add, Dock.Bottom);
        dock.Children.Add(add);
        dock.Children.Add(new ScrollViewer { Content = list, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled });
        _sidebar.Background = _p.Sidebar.B();
        _sidebar.BorderBrush = _p.Separator.B();
        _sidebar.BorderThickness = new Thickness(0, 0, 1, 0);
        _sidebar.Child = dock;
    }

    Control SidebarRow(SettingsKit k, string title, string subtitle, string icon, Color tint, bool selected, Action action)
    {
        var texts = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center, Children = { k.Text(title, 13), k.Text(subtitle, 11, c: _p.Secondary) } };
        var row = new DockPanel { Children = { k.IconSquare(icon, tint, 26).Margin2(0, 0, 10, 0), texts } };
        DockPanel.SetDock(row.Children[0], Dock.Left);
        return Selectable(row, selected, action);
    }

    Control HostRow(SettingsKit k, HostConfig host, HostSnapshot? snap, bool selected, Action action)
    {
        var icon = k.IconSquare(host.Kind.IsScheduler() ? "stack" : "server",
            host.Kind switch { HostKind.Slurm => Color.Parse("#A855F7"), HostKind.Pbs => Color.Parse("#6366F1"), _ => Color.Parse("#14B8A6") }, 26);
        var dotColor = host.Enabled ? Hue.For(snap?.Health ?? HostHealth.Unknown) : Color.Parse("#8E8E93");
        if (!host.Enabled || snap == null || snap.Health.Kind == HealthKind.Unknown) dotColor = host.Enabled ? Color.Parse("#8E8E93") : dotColor;
        var dot = new Border
        {
            Width = 10, Height = 10, CornerRadius = new CornerRadius(5), Background = dotColor.B(),
            BorderBrush = _p.Sidebar.B(), BorderThickness = new Thickness(1.5),
            HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Bottom, Margin = new Thickness(0, 0, -3, -3),
        };
        var iconBox = new Grid { Children = { icon, dot }, Margin = new Thickness(0, 0, 10, 0) };
        var nameRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, Children = { k.Text(host.DisplayName, 13) } };
        if (host.Muted) nameRow.Children.Add(new Icon("bellSlash", 10, _p.Secondary.B()) { VerticalAlignment = VerticalAlignment.Center });
        if (host.Paused) nameRow.Children.Add(new Icon("pause", 9, _p.Secondary.B()) { VerticalAlignment = VerticalAlignment.Center });
        string subtitle;
        if (!host.Enabled) subtitle = L("已停用", "Disabled");
        else if (host.Paused) subtitle = L("已暂停", "Paused");
        else subtitle = (snap?.Health.Kind ?? HealthKind.Unknown) switch
        {
            HealthKind.Ok => (snap!.RunningCount + snap.PendingCount) == 0 ? host.Kind.Label() + L(" · 空闲", " · idle")
                : L($"运行 {snap.RunningCount} · 排队 {snap.PendingCount}", $"{snap.RunningCount} running · {snap.PendingCount} pending"),
            HealthKind.NeedsLogin => L("需要登录", "Login required"),
            HealthKind.Error => snap!.Health.Message,
            _ => L("连接中…", "Connecting…"),
        };
        var texts = new StackPanel { Spacing = 1, VerticalAlignment = VerticalAlignment.Center, Children = { nameRow, k.Text(subtitle, 11, c: _p.Secondary) } };
        var row = new DockPanel { Children = { iconBox, texts } };
        DockPanel.SetDock(iconBox, Dock.Left);
        return Selectable(row, selected, action);
    }

    Control Selectable(Control content, bool selected, Action action)
    {
        var b = new Clickable(action)
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(8, 6),
            Normal = selected ? _p.Selection : Colors.Transparent,
            Hover = selected ? _p.Selection : _p.Separator,
            Child = content,
        };
        b.Cursor = Avalonia.Input.Cursor.Default;
        return b;
    }

    void BuildPage()
    {
        var k = new SettingsKit(_p);
        _pageEngineUpdate = null;
        Control page;
        switch (_kind)
        {
            case SettingsPageKind.Host when _store.Host(_hostID) is { } host:
                var hp = new HostPage(this, k, _store, _engine, _prompter, host);
                page = hp.Build();
                _pageEngineUpdate = hp.EngineChanged;
                break;
            case SettingsPageKind.Rules:
                page = new RulesPage(this, k, _store, _engine).Build();
                break;
            default:
                _kind = SettingsPageKind.General;
                var gp = new GeneralPage(this, k, _store, _engine);
                page = gp.Build();
                _pageEngineUpdate = gp.EngineChanged;
                break;
        }
        _scroll.Content = new Border { Padding = new Thickness(28, 22, 28, 28), Child = page, MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Stretch };
    }

    public void HostRemoved()
    {
        _kind = SettingsPageKind.General;
        RebuildAll();
    }
}
