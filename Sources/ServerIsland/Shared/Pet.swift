import SwiftUI

/// 刘海里的小宠物：像素小章鱼 "Tako"。八只手同时忙很多任务，正好住在岛上。
/// 心情随服务器状态变化：空闲会眨眼、有任务时手舞足蹈、排队时打瞌睡、完成时开心蹦跶、出错时晕头转向。
enum PetMood: Hashable {
    case idle
    case working
    case waiting
    case happy
    case sad
    case worried
}

enum PetSprite {
    static let width = 16
    static let height = 14

    /// 头部（不含五官）
    static let head: [String] = [
        "......BBBB......",
        "....BBBBBBBB....",
        "...BHHBBBBBBB...",
        "..BHHBBBBBBBBB..",
        "..BHBBBBBBBBBB..",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        ".BBBBBBBBBBBBBB.",
        "..SBBBBBBBBBBS..",
    ]

    static let legsA: [String] = [
        ".SBB.BB..BB.BBS.",
        ".BB..BB..BB..BB.",
        "BB..BB....BB..BB",
        "B...B......B...B",
    ]

    static let legsB: [String] = [
        ".SBB.BB..BB.BBS.",
        "..BB.BB..BB.BB..",
        "..B..BB..BB..B..",
        ".BB...B..B...BB.",
    ]

    /// 收拢的腿（开心蹦起来时）
    static let legsTucked: [String] = [
        ".SBBBBB..BBBBBS.",
        "..BB.BB..BB.BB..",
        "...B.B....B.B...",
        "................",
    ]

    /// 返回 14 行字符网格。
    static func frame(mood: PetMood, tick: Int) -> [[Character]] {
        var legs = legsA
        switch mood {
        case .working: legs = tick % 2 == 0 ? legsA : legsB
        case .happy: legs = tick % 2 == 0 ? legsTucked : legsA
        default: break
        }
        var g = (head + legs).map { Array($0) }
        func put(_ r: Int, _ c: Int, _ ch: Character) {
            guard r >= 0, r < height, c >= 0, c < width else { return }
            g[r][c] = ch
        }
        // 腮红
        put(8, 3, "C"); put(8, 12, "C")

        let blink = mood == .idle && tick % 14 == 0
        switch mood {
        case .happy:
            // ^ ^ 眯眼笑 + 张嘴
            for c in [4, 11] { put(6, c, "E"); put(7, c - 1, "E"); put(7, c + 1, "E") }
            put(8, 7, "M"); put(8, 8, "M"); put(9, 7, "C"); put(9, 8, "C")
        case .sad:
            // x x 晕了 + 撇嘴 + 一滴汗
            for c in [4, 11] {
                put(5, c - 1, "E"); put(5, c + 1, "E"); put(6, c, "E"); put(7, c - 1, "E"); put(7, c + 1, "E")
            }
            put(9, 7, "M"); put(9, 8, "M"); put(8, 6, "M"); put(8, 9, "M")
            put(2, 13, "R"); put(3, 13, "R"); put(3, 14, "R")
        case .waiting:
            // 半闭的困眼
            for c in [4, 10] { put(6, c, "S"); put(6, c + 1, "S"); put(7, c, "E"); put(7, c + 1, "E") }
        default:
            if blink {
                for c in [4, 10] { put(7, c, "E"); put(7, c + 1, "E") }
            } else {
                for c in [4, 10] { put(6, c, "W"); put(6, c + 1, "E"); put(7, c, "E"); put(7, c + 1, "E") }
            }
            if mood == .worried {
                put(2, 13, "R"); put(3, 13, "R"); put(3, 14, "R")
                put(8, 7, "M"); put(8, 8, "M")
            } else {
                put(8, 7, "M"); put(8, 8, "M")
            }
        }
        return g
    }

    static func color(_ ch: Character, mood: PetMood) -> Color? {
        let sad = mood == .sad
        switch ch {
        case "B": return sad ? Color(red: 1.00, green: 0.55, blue: 0.55) : Color(red: 0.36, green: 0.90, blue: 0.71)
        case "S": return sad ? Color(red: 0.80, green: 0.33, blue: 0.36) : Color(red: 0.18, green: 0.68, blue: 0.53)
        case "H": return sad ? Color(red: 1.00, green: 0.80, blue: 0.80) : Color(red: 0.74, green: 0.98, blue: 0.87)
        case "E", "M": return Color(red: 0.04, green: 0.06, blue: 0.12)
        case "W": return .white
        case "C": return Color(red: 1.00, green: 0.56, blue: 0.67)
        case "R": return Color(red: 0.49, green: 0.78, blue: 1.00)
        default: return nil
        }
    }
}

/// 像素宠物视图。`animated` 为 false 时渲染静态帧（预览、图标用）。
struct PetView: View {
    var mood: PetMood
    var size: CGFloat = 20
    var animated = true

    var body: some View {
        if animated {
            TimelineView(.periodic(from: .now, by: interval)) { ctx in
                let tick = Int(ctx.date.timeIntervalSinceReferenceDate / interval)
                sprite(tick: tick)
            }
        } else {
            sprite(tick: 1)
        }
    }

    /// 动画帧率很低（2–3 fps），几乎不占资源。
    private var interval: Double {
        switch mood {
        case .working: return 0.32
        case .happy: return 0.26
        case .waiting: return 0.9
        default: return 0.45
        }
    }

    private func sprite(tick: Int) -> some View {
        let px = size / CGFloat(PetSprite.height)
        let grid = PetSprite.frame(mood: mood, tick: tick)
        let bob: CGFloat = {
            switch mood {
            case .working: return tick % 2 == 0 ? 0 : -px
            case .happy: return tick % 2 == 0 ? -px * 2 : 0
            case .worried: return tick % 6 == 0 ? -px : 0
            default: return 0
            }
        }()
        return Canvas { ctx, _ in
            for (r, row) in grid.enumerated() {
                for (c, ch) in row.enumerated() {
                    guard let color = PetSprite.color(ch, mood: mood) else { continue }
                    let rect = CGRect(x: CGFloat(c) * px, y: CGFloat(r) * px + bob + px * 2, width: px + 0.5, height: px + 0.5)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: px * CGFloat(PetSprite.width), height: size + px * 2)
        .overlay(alignment: .topTrailing) {
            if mood == .waiting {
                Text(tick % 2 == 0 ? "z" : "Z")
                    .font(.system(size: max(7, size * 0.36), weight: .heavy, design: .rounded))
                    .foregroundStyle(Theme.amber.opacity(0.9))
                    .offset(x: px * 3, y: tick % 2 == 0 ? 0 : -px)
            }
        }
        .shadow(color: (mood == .sad ? Theme.coral : Theme.mint).opacity(0.35), radius: size * 0.25)
    }
}

extension MonitorEngine {
    /// 根据整体状态决定宠物心情。
    var petMood: PetMood {
        if let e = currentEvent {
            switch e.kind {
            case .failed: return .sad
            case .finished: return .happy
            default: return .working
            }
        }
        if snapshots.values.contains(where: { if case .error = $0.health { return true }; return false }) { return .sad }
        if hasProblem { return .worried }
        if totalRunning > 0 { return .working }
        if totalPending > 0 { return .waiting }
        return .idle
    }
}
