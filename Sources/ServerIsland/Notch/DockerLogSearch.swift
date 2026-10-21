import Foundation

/// 搜索当前已加载的可见文本（ANSI 已解析、时间戳按开关处理），范围使用 NSTextView 的 UTF-16 坐标。
struct DockerLogMatches: Equatable {
    var ranges: [NSRange] = []
    var capped = false

    static func find(in text: String, query: String, limit: Int = 2000) -> Self {
        guard !query.isEmpty, limit > 0 else { return Self() }
        let source = text as NSString
        var cursor = 0, result = Self()
        while cursor < source.length {
            let range = source.range(of: query, options: [.caseInsensitive, .diacriticInsensitive],
                                     range: NSRange(location: cursor, length: source.length - cursor))
            guard range.location != NSNotFound, range.length > 0 else { break }
            if result.ranges.count == limit { result.capped = true; break }
            result.ranges.append(range)
            cursor = NSMaxRange(range)
        }
        return result
    }

    static func step(_ index: Int, count: Int, direction: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((index + direction) % count + count) % count
    }

    /// 新日志追加或 tail 淘汰旧行时尽量保留当前匹配，而不是每秒重新定位第一个结果。
    func retainedIndex(previous: NSRange?, oldText: String, newText: String) -> Int {
        guard let previous, !ranges.isEmpty else { return 0 }
        var removed = 0
        if !newText.hasPrefix(oldText) {
            let head = newText.split(separator: "\n", omittingEmptySubsequences: false).prefix(3).joined(separator: "\n")
            if !head.isEmpty, let overlap = oldText.range(of: head),
               overlap.lowerBound == oldText.startIndex || oldText[oldText.index(before: overlap.lowerBound)] == "\n" {
                removed = oldText[..<overlap.lowerBound].utf16.count
            }
        }
        let location = max(0, previous.location - removed)
        return ranges.indices.min { abs(ranges[$0].location - location) < abs(ranges[$1].location - location) } ?? 0
    }
}
