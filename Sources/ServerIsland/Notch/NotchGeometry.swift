import AppKit
import SwiftUI

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    }

    var hasNotch: Bool { safeAreaInsets.top > 0 }

    /// 刘海所在矩形（全局坐标）：左右两块辅助区域之间的空隙。
    var notchRect: NSRect? {
        guard hasNotch, let l = auxiliaryTopLeftArea, let r = auxiliaryTopRightArea else { return nil }
        return NSRect(x: l.maxX, y: frame.maxY - safeAreaInsets.top, width: r.minX - l.maxX, height: safeAreaInsets.top)
    }

    /// 优先使用带刘海的内建屏幕。
    static var islandScreen: NSScreen? {
        screens.first { $0.hasNotch } ?? screens.first { CGDisplayIsBuiltin($0.displayID) != 0 } ?? main
    }
}

struct NotchGeometry: Equatable {
    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var hasNotch: Bool
    var screenFrame: NSRect

    static func current() -> NotchGeometry {
        guard let screen = NSScreen.islandScreen else {
            return NotchGeometry(notchWidth: 190, notchHeight: 32, hasNotch: false, screenFrame: .zero)
        }
        if let rect = screen.notchRect {
            return NotchGeometry(notchWidth: rect.width, notchHeight: rect.height, hasNotch: true, screenFrame: screen.frame)
        }
        // 没有刘海的屏幕：在菜单栏中间画一个"虚拟刘海"。
        let menuBar = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(notchWidth: 0, notchHeight: menuBar, hasNotch: false, screenFrame: screen.frame)
    }

    var midX: CGFloat { screenFrame.midX }
}

/// 灵动岛形状：顶部两侧是向外弯的"耳朵"（与硬件刘海的反圆角衔接），底部是普通圆角。
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let t = min(topRadius, rect.width / 4)
        let b = min(bottomRadius, (rect.width - 2 * t) / 2, rect.height - t)
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t, y: rect.minY + t),
                       control: CGPoint(x: rect.minX + t, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + t, y: rect.maxY - b))
        p.addQuadCurve(to: CGPoint(x: rect.minX + t + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t - b, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - t, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - t, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - t, y: rect.minY + t))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - t, y: rect.minY))
        p.closeSubpath()
        return p
    }
}
