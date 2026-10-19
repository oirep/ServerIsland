import SwiftUI

enum Theme {
    static let mint = Color(red: 0.35, green: 0.91, blue: 0.70)
    static let cyan = Color(red: 0.36, green: 0.76, blue: 1.00)
    static let amber = Color(red: 1.00, green: 0.75, blue: 0.30)
    static let coral = Color(red: 1.00, green: 0.43, blue: 0.43)
    static let blue = Color(red: 0.45, green: 0.62, blue: 1.00)
    static let violet = Color(red: 0.66, green: 0.55, blue: 1.00)

    static let text = Color.white.opacity(0.94)
    static let secondary = Color.white.opacity(0.58)
    static let tertiary = Color.white.opacity(0.36)
    static let hairline = Color.white.opacity(0.08)
    static let card = Color.white.opacity(0.055)
    static let track = Color.white.opacity(0.10)

    static let progress = LinearGradient(colors: [mint, cyan], startPoint: .leading, endPoint: .trailing)
    static let timeProgress = LinearGradient(colors: [Color.white.opacity(0.55), Color.white.opacity(0.85)],
                                             startPoint: .leading, endPoint: .trailing)

    static func color(for state: JobState) -> Color {
        switch state {
        case .running, .completing: return mint
        case .pending: return amber
        case .completed: return blue
        case .failed, .timeout: return coral
        case .cancelled, .other: return tertiary
        }
    }

    static func color(for health: HostHealth) -> Color {
        switch health {
        case .ok: return mint
        case .needsLogin: return amber
        case .error: return coral
        case .unknown: return tertiary
        }
    }

    /// 资源占用越高颜色越"热"。
    static func load(_ fraction: Double) -> Color {
        switch fraction {
        case ..<0.6: return mint
        case ..<0.7: return cyan
        case ..<0.85: return amber
        default: return coral
        }
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
