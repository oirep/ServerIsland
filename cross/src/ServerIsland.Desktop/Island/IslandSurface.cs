using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Threading;
using ServerIsland.Desktop.Ui;

namespace ServerIsland.Desktop.Island;

/// 灵动岛形状：顶部两侧是向外弯的"耳朵"（与屏幕顶边的反圆角衔接），底部是普通圆角。（NotchShape 的移植）
public static class NotchShape
{
    public static Geometry Path(Rect r, double topRadius, double bottomRadius, bool floating)
    {
        if (floating)
        {
            var rr = Math.Min(bottomRadius, Math.Min(r.Width, r.Height) / 2);
            return new RectangleGeometry(r, rr, rr);
        }
        double t = Math.Min(topRadius, r.Width / 4);
        double b = Math.Max(0, Math.Min(Math.Min(bottomRadius, (r.Width - 2 * t) / 2), r.Height - t));
        var g = new StreamGeometry();
        using (var c = g.Open())
        {
            c.BeginFigure(new Point(r.Left, r.Top), true);
            c.QuadraticBezierTo(new Point(r.Left + t, r.Top), new Point(r.Left + t, r.Top + t));
            c.LineTo(new Point(r.Left + t, r.Bottom - b));
            c.QuadraticBezierTo(new Point(r.Left + t, r.Bottom), new Point(r.Left + t + b, r.Bottom));
            c.LineTo(new Point(r.Right - t - b, r.Bottom));
            c.QuadraticBezierTo(new Point(r.Right - t, r.Bottom), new Point(r.Right - t, r.Bottom - b));
            c.LineTo(new Point(r.Right - t, r.Top + t));
            c.QuadraticBezierTo(new Point(r.Right - t, r.Top), new Point(r.Right, r.Top));
            c.EndFigure(true);
        }
        return g;
    }
}

/// 带弹簧动画的刘海表面。形状尺寸用弹簧（response 0.44、damping 0.78）过渡；内容按目标尺寸排版，用当前形状裁剪。
public sealed class IslandSurface : Panel
{
    sealed class Spring(double value)
    {
        public double Value = value, Velocity, Target = value;
        public bool Settled => Math.Abs(Value - Target) < 0.05 && Math.Abs(Velocity) < 0.5;

        public void Step(double dt)
        {
            const double response = 0.44, damping = 0.78;
            double w = 2 * Math.PI / response;
            double acc = -w * w * (Value - Target) - 2 * damping * w * Velocity;
            Velocity += acc * dt;
            Value += Velocity * dt;
        }

        public void Snap() { Value = Target; Velocity = 0; }
    }

    readonly Spring _w = new(96), _h = new(7), _tr = new(0), _br = new(3.5);
    readonly Spring _shadow = new(0);
    readonly ShapeLayer _shape;
    readonly Decorator _host = new() { ClipToBounds = false };
    IslandLayout.ShapeSpec _target = new(96, 7, 0, 3.5);
    bool _animating;
    double _contentOpacity = 1, _contentScale = 1;
    DateTime _contentShownAt = DateTime.MinValue;
    bool _contentFancy;
    TimeSpan? _lastFrame;

    /// 桌宠模式：四角圆角，没有耳朵。
    public bool Floating { get; set; }
    /// 形状贴着窗口底边（桌宠在屏幕下半部分时，面板往上展开）。
    public bool AnchorBottom { get; set; }
    /// 给自检用：形状当前是否贴着窗口顶边。
    public bool AtTop => CurrentRect.Y < 1;
    /// 形状当前（动画中的）矩形，窗口坐标。
    public Rect CurrentRect => ShapeRect(_w.Value, _h.Value);
    /// 动画结束后的矩形。
    public Rect TargetRect => ShapeRect(_target.Width, _target.Height);
    public event Action? AnimationFinished;

    public IslandSurface()
    {
        _shape = new ShapeLayer(this);
        Children.Add(_shape);
        Children.Add(_host);
        ClipToBounds = false;
    }

    Size _size;

    Rect ShapeRect(double w, double h)
    {
        var size = _size.Width > 0 ? _size : Bounds.Size;
        var x = (size.Width - w) / 2;
        var y = AnchorBottom ? size.Height - h - ShadowMargin : 0;
        return new Rect(x, y, Math.Max(0, w), Math.Max(0, h));
    }

    public const double ShadowMargin = 34;

    /// 设置目标形状。animate = false 时直接跳到目标（第一次显示、预览渲染）。
    public void SetTarget(IslandLayout.ShapeSpec spec, double shadowStrength, bool animate)
    {
        _target = spec;
        _w.Target = spec.Width; _h.Target = spec.Height; _tr.Target = spec.TopRadius; _br.Target = spec.BottomRadius;
        _shadow.Target = shadowStrength;
        // 目标尺寸变了，内容要按新尺寸重新测量（只重新排列会沿用旧的宽度）。
        InvalidateMeasure();
        _host.InvalidateMeasure();
        if (!animate || Preview.PreviewRenderer.Active)
        {
            foreach (var s in new[] { _w, _h, _tr, _br, _shadow }) s.Snap();
            InvalidateArrange();
            _shape.InvalidateVisual();
            return;
        }
        StartAnimation();
    }

    /// 换上新的内容。fancy = true 时淡入（模式切换时），否则直接替换（数据刷新）。
    public void SetContent(Control? content, bool fancy)
    {
        _host.Child = content;
        _contentFancy = fancy && !Preview.PreviewRenderer.Active;
        if (_contentFancy)
        {
            _contentShownAt = DateTime.Now;
            _contentOpacity = 0;
            _contentScale = 0.96;
            ApplyContentTransition();
            StartAnimation();
        }
        else
        {
            _contentOpacity = 1;
            _contentScale = 1;
            ApplyContentTransition();
        }
        InvalidateArrange();
    }

    void ApplyContentTransition()
    {
        if (_host.Child is not { } c) return;
        c.Opacity = _contentOpacity;
        c.RenderTransformOrigin = new RelativePoint(0.5, 0, RelativeUnit.Relative);
        c.RenderTransform = Math.Abs(_contentScale - 1) < 0.001 ? null : new ScaleTransform(_contentScale, _contentScale);
    }

    void StartAnimation()
    {
        if (_animating) return;
        _animating = true;
        _lastFrame = null;
        RequestFrame();
    }

    void RequestFrame()
    {
        var top = TopLevel.GetTopLevel(this);
        if (top == null) { Dispatcher.UIThread.Post(() => OnFrame(TimeSpan.FromMilliseconds(Environment.TickCount64)), DispatcherPriority.Render); return; }
        top.RequestAnimationFrame(OnFrame);
    }

    void OnFrame(TimeSpan t)
    {
        double dt = _lastFrame is { } last ? Math.Clamp((t - last).TotalSeconds, 0.001, 1 / 30.0) : 1 / 60.0;
        _lastFrame = t;
        bool settled = true;
        foreach (var s in new[] { _w, _h, _tr, _br, _shadow })
        {
            if (s.Settled) { s.Snap(); continue; }
            s.Step(dt);
            settled = false;
        }
        if (_contentFancy)
        {
            // 内容在形状展开时稍微延后淡入（0.1 秒后，0.28 秒内完成）
            var e = (DateTime.Now - _contentShownAt).TotalSeconds - 0.1;
            var p = Math.Clamp(e / 0.28, 0, 1);
            var eased = 1 - Math.Pow(1 - p, 3);
            _contentOpacity = eased;
            _contentScale = 0.96 + 0.04 * eased;
            ApplyContentTransition();
            if (p < 1) settled = false; else _contentFancy = false;
        }
        InvalidateArrange();
        _shape.InvalidateVisual();
        if (settled)
        {
            _animating = false;
            AnimationFinished?.Invoke();
            return;
        }
        RequestFrame();
    }

    protected override Size MeasureOverride(Size availableSize)
    {
        _shape.Measure(availableSize);
        _host.Measure(new Size(Math.Max(0, _target.Width - 2 * _target.TopRadius), _target.Height));
        return availableSize;
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        _size = finalSize;
        _shape.Arrange(new Rect(finalSize));
        // 内容按目标尺寸排版（居中），用当前形状裁剪
        var target = ShapeRect(_target.Width, _target.Height);
        var contentRect = new Rect(target.X + _target.TopRadius, target.Y, Math.Max(0, _target.Width - 2 * _target.TopRadius), _target.Height);
        _host.Arrange(contentRect);
        var cur = CurrentRect;
        var clip = NotchShape.Path(new Rect(cur.X - contentRect.X, cur.Y - contentRect.Y, cur.Width, cur.Height), _tr.Value, _br.Value, Floating);
        _host.Clip = clip;
        return finalSize;
    }

    /// 真正画形状的层（带阴影和边缘高光）。
    sealed class ShapeLayer(IslandSurface owner) : Control
    {
        public override void Render(DrawingContext ctx)
        {
            var r = owner.CurrentRect;
            if (r.Width < 1 || r.Height < 1) return;
            var geo = NotchShape.Path(r, owner._tr.Value, owner._br.Value, owner.Floating);
            double s = Math.Clamp(owner._shadow.Value, 0, 1);
            if (s > 0.01)
            {
                // 投影：只给"身体"（去掉两侧耳朵）画一个高斯模糊的圆角矩形阴影，和 SwiftUI 版的 shadow(radius 22, y 8) 接近。
                double t = owner.Floating ? 0 : Math.Min(owner._tr.Value, r.Width / 4);
                double b = Math.Min(owner._br.Value, Math.Min((r.Width - 2 * t) / 2, r.Height));
                var body = new Rect(r.X + t, r.Y, Math.Max(0, r.Width - 2 * t), r.Height);
                var top = owner.Floating ? b : 0;
                var rr = new RoundedRect(body, new Vector(top, top), new Vector(top, top), new Vector(b, b), new Vector(b, b));
                var shadow = new BoxShadows(new BoxShadow { Blur = 22 * s + 6, OffsetY = 8 * s, Color = Colors.Black.WithAlpha(0.5 * s) });
                ctx.DrawRectangle(Brushes.Black, null, rr, shadow);
            }
            ctx.DrawGeometry(Brushes.Black, null, geo);
            // 展开时沿边缘一圈极淡的高光，深色背景上也能看清轮廓；收起时把手也描一圈，免得在深色窗口上看不见。
            var strokeAlpha = Math.Max(s, owner._target.Height <= IslandLayout.HandleHeight + 0.5 ? 0.6 : 0);
            if (strokeAlpha > 0.01)
                ctx.DrawGeometry(null, new Pen(Hue.Vertical(Hue.W(0.0), Hue.W(0.12 * strokeAlpha)), 1), geo);
        }
    }
}
