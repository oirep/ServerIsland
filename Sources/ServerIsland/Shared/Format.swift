import Foundation

enum Format {
    /// 3725 -> "1:02:05"，超过一天 -> "2d 03:10"
    static func duration(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60, sec = s % 60
        if d > 0 { return String(format: "%dd %02d:%02d", d, h, m) }
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, sec) }
        return String(format: "%d:%02d", m, sec)
    }

    /// 简短时长，用于空间很小的地方："42m" "3.5h" "2d"
    static func shortDuration(_ t: TimeInterval) -> String {
        let s = max(0, t)
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        if s < 86400 { return String(format: s < 36000 ? "%.1fh" : "%.0fh", s / 3600) }
        return String(format: "%.0fd", s / 86400)
    }

    static func relative(_ date: Date, now: Date = Date()) -> String {
        let s = now.timeIntervalSince(date)
        if s < 5 { return L("刚刚", "just now") }
        if s < 60 { return L("\(Int(s))秒前", "\(Int(s))s ago") }
        if s < 3600 { return L("\(Int(s / 60))分钟前", "\(Int(s / 60))m ago") }
        if s < 86400 { return L("\(Int(s / 3600))小时前", "\(Int(s / 3600))h ago") }
        return L("\(Int(s / 86400))天前", "\(Int(s / 86400))d ago")
    }

    static func bytes(_ b: Double) -> String {
        let gb = b / 1_073_741_824
        if gb >= 100 { return String(format: "%.0fG", gb) }
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", b / 1_048_576)
    }

    static func percent(_ v: Double) -> String {
        "\(Int((v * 100).rounded()))%"
    }
}
