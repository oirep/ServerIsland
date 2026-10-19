import SwiftUI
import AppKit

/// Docker 原始日志可能混有终端控制码；仅解释文字颜色，不执行光标或链接控制。
enum DockerLogText {
    /// 显式转换为 AppKit 颜色，避免 SwiftUI 的统一 foregroundStyle 覆盖日志分段颜色。
    static func native(_ text: AttributedString) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for run in text.runs {
            let bold = run.font == Theme.mono(10.5).weight(.bold)
            result.append(NSAttributedString(string: String(text[run.range].characters), attributes: [
                .foregroundColor: NSColor(run.foregroundColor ?? Theme.secondary),
                .font: NSFont.monospacedSystemFont(ofSize: 10.5, weight: bold ? .bold : .regular)
            ]))
        }
        return result
    }

    static func render(_ source: String, showTimestamps: Bool = true) -> AttributedString {
        // 只隐藏 Docker 在每行起始添加的 RFC3339 时间戳，不改动应用正文里的日期。
        let visible = showTimestamps ? source : source.replacingOccurrences(
            of: #"(?m)^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})[ \t]"#,
            with: "", options: .regularExpression)
        let input = Array(visible.unicodeScalars)
        var result = AttributedString()
        var buffer = ""
        var foreground: Color = Theme.secondary
        var bold = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var part = AttributedString(buffer)
            part.foregroundColor = foreground
            part.font = Theme.mono(10.5).weight(bold ? .bold : .regular)
            result.append(part)
            buffer = ""
        }
        var i = 0
        while i < input.count {
            let value = input[i].value
            if value == 27 {
                flush()
                i += 1
                guard i < input.count else { break }
                if input[i] == "[" {
                    i += 1
                    let start = i
                    while i < input.count && !(0x40...0x7e).contains(input[i].value) { i += 1 }
                    if i < input.count && input[i] == "m" {
                        let raw = String(String.UnicodeScalarView(input[start..<i]))
                        let codes = raw.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
                        var n = 0
                        while n < codes.count {
                            let code = codes[n]
                            switch code {
                            case 0: foreground = Theme.secondary; bold = false
                            case 1: bold = true
                            case 22: bold = false
                            case 39: foreground = Theme.secondary
                            case 30...37: foreground = palette(code - 30)
                            case 90...97: foreground = palette(code - 90 + 8)
                            case 38, 48, 58:
                                // 背景和下划线颜色也消耗完整参数，避免把 RGB 数值误当作新指令。
                                if n + 2 < codes.count && codes[n + 1] == 5 {
                                    if code == 38 { foreground = indexed(codes[n + 2]) }
                                    n += 2
                                } else if n + 4 < codes.count && codes[n + 1] == 2 {
                                    if code == 38 { foreground = readable(codes[n + 2], codes[n + 3], codes[n + 4]) }
                                    n += 4
                                }
                            default: break
                            }
                            n += 1
                        }
                    }
                    if i < input.count { i += 1 }
                } else if input[i] == "]" {
                    // OSC（包括超链接）仅保留后续可见文字，不显示或打开控制内容。
                    i += 1
                    while i < input.count {
                        if input[i].value == 7 { i += 1; break }
                        if input[i].value == 27 && i + 1 < input.count && input[i + 1] == "\\" { i += 2; break }
                        i += 1
                    }
                } else { i += 1 }
                continue
            }
            if value >= 32 || value == 9 || value == 10 { buffer.unicodeScalars.append(input[i]) }
            i += 1
        }
        flush()
        return result
    }

    static func palette(_ index: Int) -> Color {
        let colors: [(Int, Int, Int)] = [
            (115,115,115), (230,90,90), (90,195,125), (220,190,85),
            (105,150,235), (195,125,215), (85,190,200), (195,195,195),
            (150,150,150), (255,120,120), (125,225,155), (245,215,115),
            (140,180,255), (225,155,245), (120,220,230), (240,240,240)
        ]
        let rgb = colors[min(15, max(0, index))]
        return Color(red: Double(rgb.0) / 255, green: Double(rgb.1) / 255, blue: Double(rgb.2) / 255)
    }

    private static func indexed(_ index: Int) -> Color {
        let index = min(255, max(0, index))
        if index < 16 { return palette(index) }
        if index >= 232 { let gray = 8 + (index - 232) * 10; return readable(gray, gray, gray) }
        let n = index - 16
        let levels = [0, 95, 135, 175, 215, 255]
        return readable(levels[n / 36], levels[(n / 6) % 6], levels[n % 6])
    }

    /// 在黑色岛面上提亮过暗颜色，保持色相，避免原日志的黑/深蓝文字不可见。
    private static func readable(_ red: Int, _ green: Int, _ blue: Int) -> Color {
        var rgb = [red, green, blue].map { Double(min(255, max(0, $0))) / 255 }
        let luminance = rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
        if luminance < 0.42 {
            let lift = (0.42 - luminance) / (1 - luminance)
            rgb = rgb.map { $0 + (1 - $0) * lift }
        }
        return Color(red: rgb[0], green: rgb[1], blue: rgb[2])
    }
}
