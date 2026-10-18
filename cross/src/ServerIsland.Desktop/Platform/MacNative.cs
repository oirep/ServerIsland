using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Controls;

namespace ServerIsland.Desktop.Platform;

/// macOS 上试用跨平台版时用到的少量 Objective-C 调用（正式的 Mac 版仍然是 Swift）：
/// - 窗口层级盖过菜单栏、出现在所有桌面空间，并且能放到屏幕最顶端（贴着刘海）；
/// - 读取硬件刘海的位置和大小，让两侧小翅膀像 Swift 版一样分在刘海两边；
/// - 点击穿透：鼠标不在形状上时 ignoresMouseEvents = YES。
public static class MacNative
{
    [StructLayout(LayoutKind.Sequential)] public struct CGPoint { public double X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct CGSize { public double W, H; }
    [StructLayout(LayoutKind.Sequential)] public struct CGRect { public CGPoint O; public CGSize S; public double MaxY => O.Y + S.H; public double MaxX => O.X + S.W; }
    [StructLayout(LayoutKind.Sequential)] struct NSEdgeInsets { public double Top, Left, Bottom, Right; }

    const string ObjC = "/usr/lib/libobjc.A.dylib";
    [DllImport(ObjC)] static extern IntPtr objc_getClass(string name);
    [DllImport(ObjC)] static extern IntPtr sel_registerName(string name);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern IntPtr Msg(IntPtr r, IntPtr s);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgBool(IntPtr r, IntPtr s, bool v);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgLong(IntPtr r, IntPtr s, long v);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgPoint(IntPtr r, IntPtr s, CGPoint p);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern void MsgRectBool(IntPtr r, IntPtr s, CGRect rect, bool display);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern CGRect MsgRect(IntPtr r, IntPtr s);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern CGPoint MsgGetPoint(IntPtr r, IntPtr s);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern NSEdgeInsets MsgInsets(IntPtr r, IntPtr s);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern IntPtr MsgIndex(IntPtr r, IntPtr s, ulong i);
    [DllImport(ObjC, EntryPoint = "objc_msgSend")] static extern ulong MsgULong(IntPtr r, IntPtr s);

    static IntPtr Sel(string n) => sel_registerName(n);

    public static IntPtr NSWindow(Window w)
    {
        if (!OperatingSystem.IsMacOS()) return IntPtr.Zero;
        var h = w.TryGetPlatformHandle();
        if (h == null || h.Handle == IntPtr.Zero) return IntPtr.Zero;
        // Avalonia 给的可能是 NSView，也可能是 NSWindow
        if (h.HandleDescriptor == "NSWindow") return h.Handle;
        var win = Msg(h.Handle, Sel("window"));
        return win != IntPtr.Zero ? win : h.Handle;
    }

    /// 盖过菜单栏（和 Swift 版一样：statusBar 层级 + 8），出现在所有桌面空间、全屏 App 旁边也能看到。
    public static void MakeOverlay(Window w)
    {
        var win = NSWindow(w);
        if (win == IntPtr.Zero) return;
        MsgLong(win, Sel("setLevel:"), 25 + 8);   // NSStatusWindowLevel = 25
        // canJoinAllSpaces | stationary | ignoresCycle | fullScreenAuxiliary
        MsgLong(win, Sel("setCollectionBehavior:"), 1 | 16 | 64 | 256);
        MsgBool(win, Sel("setHasShadow:"), false);
    }

    static IntPtr MainScreen()
    {
        // 优先用带刘海的屏幕（和 Swift 版的 NSScreen.islandScreen 一样）
        var screens = Msg(objc_getClass("NSScreen"), Sel("screens"));
        var count = MsgULong(screens, Sel("count"));
        for (ulong i = 0; i < count; i++)
        {
            var s = MsgIndex(screens, Sel("objectAtIndex:"), i);
            if (MsgInsets(s, Sel("safeAreaInsets")).Top > 0) return s;
        }
        return Msg(objc_getClass("NSScreen"), Sel("mainScreen"));
    }

    /// 刘海的宽和高（没有刘海时宽为 0，高为菜单栏高度），以及屏幕的 frame。
    public static (double NotchWidth, double NotchHeight, CGRect Screen) NotchInfo()
    {
        var s = MainScreen();
        var frame = MsgRect(s, Sel("frame"));
        var insets = MsgInsets(s, Sel("safeAreaInsets"));
        if (insets.Top > 0)
        {
            var l = MsgRect(s, Sel("auxiliaryTopLeftArea"));
            var r = MsgRect(s, Sel("auxiliaryTopRightArea"));
            return (Math.Max(0, r.O.X - l.MaxX), insets.Top, frame);
        }
        var visible = MsgRect(s, Sel("visibleFrame"));
        return (0, Math.Max(frame.MaxY - visible.MaxY, 24), frame);
    }

    /// 把窗口放到屏幕最顶端、水平居中（不受"窗口不能盖住菜单栏"的限制）。
    public static void PlaceAtTop(Window w, double width, double height)
    {
        var win = NSWindow(w);
        if (win == IntPtr.Zero) return;
        var (_, _, screen) = NotchInfo();
        var rect = new CGRect { O = new CGPoint { X = screen.O.X + (screen.S.W - width) / 2, Y = screen.MaxY - height }, S = new CGSize { W = width, H = height } };
        MsgRectBool(win, Sel("setFrame:display:"), rect, true);
    }

    public static void SetIgnoresMouse(Window w, bool ignore)
    {
        var win = NSWindow(w);
        if (win != IntPtr.Zero) MsgBool(win, Sel("setIgnoresMouseEvents:"), ignore);
    }

    /// 鼠标在窗口里的位置（窗口坐标，左上角为原点，单位和 Avalonia 的 DIP 一致）。
    public static Point? CursorInWindow(Window w)
    {
        var win = NSWindow(w);
        if (win == IntPtr.Zero) return null;
        var p = MsgGetPoint(objc_getClass("NSEvent"), Sel("mouseLocation"));
        var f = MsgRect(win, Sel("frame"));
        return new Point(p.X - f.O.X, f.MaxY - p.Y);
    }
}
