using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Styling;
using Avalonia.Threading;
using ServerIsland.Core;
using ServerIsland.Desktop.Platform;
using ServerIsland.Desktop.Ui;
using static ServerIsland.Core.Lang;
using static ServerIsland.Desktop.Ui.Kit;

namespace ServerIsland.Desktop.Island;

/// 桌宠模式：小章鱼 Tako 待在桌面上（可以拖到任何地方），身上的小徽章显示运行数 / 排队数 / 异常。
/// 鼠标移上去展开面板，点一下固定面板，事件提示从它身边弹出。
public sealed class PetWindow : Window
{
    readonly MonitorEngine _engine;
    readonly ConfigStore _store;
    readonly IslandWindow _island;
    readonly Grid _root = new();
    PetMood _mood = (PetMood)(-1);
    string _badgeKey = "";
    PixelPoint _pressPosition;
    bool _pressed;

    public const double Size = 64;

    public PetWindow(MonitorEngine engine, ConfigStore store, IslandWindow island)
    {
        _engine = engine;
        _store = store;
        _island = island;
        Title = "ServerIsland";
        SystemDecorations = SystemDecorations.None;
        TransparencyLevelHint = [WindowTransparencyLevel.Transparent];
        Background = Brushes.Transparent;
        Topmost = true;
        ShowInTaskbar = false;
        CanResize = false;
        ShowActivated = false;
        RequestedThemeVariant = ThemeVariant.Dark;
        Width = Size;
        Height = Size;
        WindowStartupLocation = WindowStartupLocation.Manual;
        Icon = App.WindowIcon;
        Content = _root;
        Cursor = new Cursor(StandardCursorType.Hand);

        PointerEntered += (_, _) => _island.SetPetHover(true);
        PointerExited += (_, _) => _island.SetPetHover(false);
        PointerPressed += OnPressed;
        PointerReleased += (_, _) =>
        {
            if (!_pressed) return;
            _pressed = false;
            if (Position == _pressPosition) _island.TogglePinned();
        };
        PositionChanged += (_, _) => SavePositionSoon();
        ToolTip.SetTip(this, L("拖动可以移动；点一下固定面板", "Drag to move; click to pin the panel"));
        Refresh();
    }

    protected override void OnOpened(EventArgs e)
    {
        base.OnOpened(e);
        Native.SetToolWindow(this);
        Native.SetNoActivate(this, true);
        PlaceInitially();
    }

    void PlaceInitially()
    {
        var screen = Screens.Primary ?? Screens.All.FirstOrDefault();
        if (screen == null) return;
        var scale = screen.Scaling;
        int s = (int)Math.Round(Size * scale);
        if (_store.Settings.PetX is { } x && _store.Settings.PetY is { } y
            && Screens.All.Any(sc => sc.WorkingArea.Contains(new PixelPoint(x + s / 2, y + s / 2))))
        {
            Position = new PixelPoint(x, y);
            return;
        }
        var work = screen.WorkingArea;
        Position = new PixelPoint(work.Right - s - (int)(36 * scale), work.Bottom - s - (int)(36 * scale));
    }

    void OnPressed(object? sender, PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _pressed = true;
        _pressPosition = Position;
        BeginMoveDrag(e);
        // Windows 上 BeginMoveDrag 会进入系统的移动循环，结束后才返回；没有移动就当作点击。
        if (OperatingSystem.IsWindows())
        {
            _pressed = false;
            if (Position == _pressPosition) _island.TogglePinned();
        }
    }

    IDisposable? _saveTimer;

    void SavePositionSoon()
    {
        _island.Reposition();
        _saveTimer?.Dispose();
        _saveTimer = DispatcherTimer.RunOnce(() =>
        {
            _store.Settings.PetX = Position.X;
            _store.Settings.PetY = Position.Y;
            _store.Touch();
        }, TimeSpan.FromSeconds(0.8));
    }

    public PixelRect ScreenRect => new(Position, new PixelSize((int)Math.Round(Bounds.Width * RenderScaling), (int)Math.Round(Bounds.Height * RenderScaling)));

    /// 根据整体状态更新心情和徽章（只有变化时才重建）。
    public void Refresh()
    {
        var mood = _engine.PetMood;
        int running = _engine.TotalRunning, pending = _engine.TotalPending;
        bool problem = _engine.HasProblem, error = _engine.HasError;
        var key = $"{running}|{pending}|{problem}|{error}";
        if (mood == _mood && key == _badgeKey) return;
        _mood = mood;
        _badgeKey = key;

        _root.Children.Clear();
        var bg = new Border
        {
            Width = 52, Height = 52, CornerRadius = new CornerRadius(18),
            Background = Brushes.Black,
            BorderBrush = Hue.W(0.14).B(), BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center,
            BoxShadow = new BoxShadows(new BoxShadow { Blur = 10, OffsetY = 3, Color = Colors.Black.WithAlpha(0.45) }),
            Child = new PetView(mood, 30) { HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
        };
        _root.Children.Add(bg);

        Control? badge = null;
        if (problem && running == 0)
            badge = Badge(new Icon("exclamation", 9, Brushes.Black, 3.6), error ? Hue.Coral : Hue.Amber);
        else if (running > 0)
            badge = Badge(T($"{running}", 10, FontWeight.Bold, Colors.Black), Hue.Mint);
        else if (pending > 0)
            badge = Badge(T($"{pending}", 10, FontWeight.Bold, Colors.Black), Hue.Amber);
        if (badge != null) _root.Children.Add(badge);
    }

    static Control Badge(Control content, Color c) => new Border
    {
        MinWidth = 18, Height = 18, CornerRadius = new CornerRadius(9), Background = c.B(),
        BorderBrush = Brushes.Black, BorderThickness = new Thickness(2), Padding = new Thickness(4, 0),
        HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Top, Margin = new Thickness(0, 2, 2, 0),
        Child = new Border { Child = content, HorizontalAlignment = HorizontalAlignment.Center, VerticalAlignment = VerticalAlignment.Center },
    };
}
