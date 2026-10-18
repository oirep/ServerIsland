using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Media.Imaging;
using Avalonia.Platform;
using Avalonia.Styling;
using Avalonia.Themes.Fluent;
using Avalonia.Threading;
using ServerIsland.Core;
using ServerIsland.Desktop.Island;
using ServerIsland.Desktop.Platform;
using ServerIsland.Desktop.Settings;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop;

public sealed class App : Application
{
    public static bool AskPassMode;
    public static WindowIcon? WindowIcon;
    public static App? Instance;

    ConfigStore _store = null!;
    MonitorEngine _engine = null!;
    IslandWindow _island = null!;
    PetWindow? _pet;
    SettingsWindow? _settings;
    TrayController? _tray;
    LoginPrompter _prompter = new();
    DisplayMode? _displayMode;

    public override void Initialize()
    {
        Styles.Add(new FluentTheme());
        RequestedThemeVariant = ThemeVariant.Default;
        Name = "ServerIsland";
        try { WindowIcon = new WindowIcon(AssetLoader.Open(new Uri("avares://ServerIsland/Assets/AppIcon.png"))); } catch { }
        Instance = this;
    }

    public override void OnFrameworkInitializationCompleted()
    {
        base.OnFrameworkInitializationCompleted();
        if (AskPassMode || Preview.PreviewRenderer.Active) return;
        if (ApplicationLifetime is not IClassicDesktopStyleApplicationLifetime desktop) return;
        desktop.ShutdownMode = ShutdownMode.OnExplicitShutdown;

        // 界面线程上的异常：记日志后继续运行，不让整个程序消失。
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            DebugLog.Log("界面异常：" + e.Exception);
            Preview.UiSmoke.Errors.Add(e.Exception.ToString());
            e.Handled = true;
        };
        bool demo = Program.Demo;
        _store = new ConfigStore(persist: !demo);
        if (demo) _store.Replace(DemoData.Settings());
        _engine = new MonitorEngine(_store, demo);
        _engine.PlaySound = Sound.Play;
        _engine.EventEmitted += e =>
        {
            if (_store.Settings.SystemNotifications && !demo && e.Kind != EventKind.Started && Notifier.Supported)
                Notifier.Post(e, _store.Settings.SoundEnabled);
        };

        _island = new IslandWindow(_engine, _store, _prompter);
        _island.State.OpenSettings = () => { _island.SetHovering(false); ShowSettings(); };
        _tray = new TrayController(this, _engine, _store);

        _engine.Changed += OnEngineChanged;
        _store.Changed += OnStoreChanged;
        ApplyDisplayMode();
        _engine.Start();
        desktop.Exit += (_, _) => _store.SaveNow();

        if (Preview.UiSmoke.Directory != null) Preview.UiSmoke.Run(this, _engine, _store, _island);

        // 第一次启动：直接打开设置，引导添加服务器。
        if (_store.Settings.Hosts.Count == 0 && !demo)
            DispatcherTimer.RunOnce(ShowSettings, TimeSpan.FromSeconds(0.6));
        DebugLog.Log($"ServerIsland {AppInfo.Version} 启动（{Environment.OSVersion}，SSH：{_engine.Ssh.Name}）");
        // 按设置的天数清理诊断日志：启动时一次，之后每 6 小时一次。
        DebugLog.Prune(_store.Settings.LogRetentionDays);
        DispatcherTimer.Run(() => { DebugLog.Prune(_store.Settings.LogRetentionDays); return true; }, TimeSpan.FromHours(6));
    }

    bool _refreshQueued;

    void OnEngineChanged()
    {
        if (_refreshQueued) return;
        _refreshQueued = true;
        Dispatcher.UIThread.Post(() =>
        {
            _refreshQueued = false;
            _island.RequestRebuild();
            _pet?.Refresh();
            _tray?.Update();
            _settings?.EngineChanged();
        }, DispatcherPriority.Background);
    }

    SshBackend _backend;

    void OnStoreChanged()
    {
        if (_store.Settings.SshBackend != _backend)
        {
            _backend = _store.Settings.SshBackend;
            _engine.SetSshBackend(_backend);
        }
        ApplyDisplayMode();
        OnEngineChanged();
    }

    void ApplyDisplayMode()
    {
        _backend = _store.Settings.SshBackend;
        var mode = _store.Settings.DisplayMode;
        if (mode == _displayMode) return;
        _displayMode = mode;
        if (mode == DisplayMode.Pet)
        {
            _pet ??= new PetWindow(_engine, _store, _island);
            _island.FloatingAnchor = () => _pet.IsVisible ? _pet.ScreenRect : null;
            _pet.Show();
            _island.Hide();
        }
        else
        {
            _island.FloatingAnchor = null;
            _pet?.Hide();
            _island.Show();
            _island.Reposition();
        }
        _island.State.Hovering = false;
        _island.Rebuild();
    }

    public void ShowSettings()
    {
        if (_settings == null)
        {
            _settings = new SettingsWindow(_store, _engine, _prompter);
            _settings.Closed += (_, _) => _settings = null;
        }
        _settings.Show();
        _settings.Activate();
    }

    public void TogglePanel() => _island.TogglePinned();

    public PetWindow? PetWindow => _pet;
    public SettingsWindow? Settings => _settings;

    public void SetDisplayMode(DisplayMode mode)
    {
        _store.Settings.DisplayMode = mode;
        _store.Touch();
    }

    public void Quit()
    {
        _store.SaveNow();
        (ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)?.Shutdown();
    }
}

/// 托盘图标（Windows 通知区域 / Linux 状态栏）：点击打开面板，右键菜单里有各服务器状态、刷新、设置、显示方式、退出。
public sealed class TrayController
{
    readonly App _app;
    readonly MonitorEngine _engine;
    readonly ConfigStore _store;
    readonly TrayIcon _icon;
    readonly WindowIcon? _normal, _alert;
    bool? _lastAlert;

    public TrayController(App app, MonitorEngine engine, ConfigStore store)
    {
        _app = app;
        _engine = engine;
        _store = store;
        try
        {
            _normal = new WindowIcon(AssetLoader.Open(new Uri("avares://ServerIsland/Assets/Tray.png")));
            _alert = new WindowIcon(AssetLoader.Open(new Uri("avares://ServerIsland/Assets/TrayAlert.png")));
        }
        catch { }
        var menu = new NativeMenu();
        menu.NeedsUpdate += (_, _) => BuildMenu(menu);
        BuildMenu(menu);
        _icon = new TrayIcon { Icon = _normal, ToolTipText = "ServerIsland", Menu = menu, IsVisible = true };
        _icon.Clicked += (_, _) => _app.TogglePanel();
        TrayIcon.SetIcons(Application.Current!, [_icon]);
        Update();
    }

    public void Update()
    {
        bool alert = _engine.HasError;
        if (alert != _lastAlert)
        {
            _lastAlert = alert;
            _icon.Icon = alert ? _alert : _normal;
        }
        _icon.ToolTipText = "ServerIsland · " + L($"运行 {_engine.TotalRunning} · 排队 {_engine.TotalPending}", $"{_engine.TotalRunning} running · {_engine.TotalPending} pending");
        if (_icon.Menu is { } m) BuildMenu(m);
    }

    void BuildMenu(NativeMenu menu)
    {
        menu.Items.Clear();
        var hosts = _engine.OrderedHosts;
        if (hosts.Count == 0) menu.Items.Add(new NativeMenuItem(L("还没有添加服务器", "No servers yet")) { IsEnabled = false });
        foreach (var (host, snap) in hosts)
        {
            var status = snap.Health.Kind switch
            {
                HealthKind.Ok => L($"运行 {snap.RunningCount} · 排队 {snap.PendingCount}", $"{snap.RunningCount} running · {snap.PendingCount} pending"),
                HealthKind.Unknown => L("连接中…", "Connecting…"),
                _ => snap.Health.Message,
            };
            var dot = snap.Health.Kind switch { HealthKind.Ok => "🟢", HealthKind.NeedsLogin => "🟡", HealthKind.Error => "🔴", _ => "⚪" };
            menu.Items.Add(new NativeMenuItem($"{dot}  {host.DisplayName} — {status}") { IsEnabled = false });
        }
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item(L("打开面板", "Open Panel"), _app.TogglePanel));
        menu.Items.Add(Item(L("立即刷新", "Refresh Now"), _engine.RefreshAll));
        var mode = new NativeMenuItem(L("显示方式", "Display")) { Menu = new NativeMenu() };
        foreach (var dm in Enum.GetValues<DisplayMode>())
        {
            var d = dm;
            var it = Item(dm.Label(), () => _app.SetDisplayMode(d));
            it.ToggleType = NativeMenuItemToggleType.Radio;
            it.IsChecked = _store.Settings.DisplayMode == dm;
            mode.Menu.Items.Add(it);
        }
        menu.Items.Add(mode);
        menu.Items.Add(Item(L("设置…", "Settings…"), _app.ShowSettings));
        menu.Items.Add(new NativeMenuItemSeparator());
        menu.Items.Add(Item(L("退出 ServerIsland", "Quit ServerIsland"), _app.Quit));
    }

    static NativeMenuItem Item(string title, Action action)
    {
        var i = new NativeMenuItem(title);
        i.Click += (_, _) => action();
        return i;
    }
}
