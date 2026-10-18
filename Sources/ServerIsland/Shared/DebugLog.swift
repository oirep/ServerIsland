import Foundation

/// 轻量诊断日志：~/Library/Logs/ServerIsland/serverisland.log（超过 512KB 自动轮转成 serverisland.1.log）。
/// 记录轮询结果、任务消失、提醒是否发出以及原因，方便排查"为什么没提醒"。
/// 超过保留天数（设置 → 通用，默认 7 天）的行自动删除；也可以一键清空。
enum DebugLog {
    static let url: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ServerIsland")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("serverisland.log")
    }()

    private static let queue = DispatchQueue(label: "serverisland.log")
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static var rotatedURL: URL { url.deletingPathExtension().appendingPathExtension("1.log") }

    /// 删除早于 days 天的行（0 表示永久保留）。没有时间戳的行（多行消息的后续行）跟随上一行。
    static func prune(days: Int, now: Date = Date()) {
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86400)
        queue.async {
            for file in [rotatedURL, url] {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let kept = pruneText(text, cutoff: cutoff, now: now)
                if kept == text { continue }
                if kept.isEmpty { try? FileManager.default.removeItem(at: file) }
                else { try? Data(kept.utf8).write(to: file, options: .atomic) }
            }
        }
    }

    /// 只保留 cutoff 之后的行。旧版本的时间戳没有年份（"MM-dd HH:mm:ss"），按今年算，晚于现在就算去年。
    static func pruneText(_ text: String, cutoff: Date, now: Date = Date()) -> String {
        let old = DateFormatter()
        old.dateFormat = "yyyy-MM-dd HH:mm:ss"
        old.locale = Locale(identifier: "en_US_POSIX")
        let year = Calendar.current.component(.year, from: now)
        var keep = true
        var out: [Substring] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.count >= 19, let d = formatter.date(from: String(line.prefix(19))) {
                keep = d >= cutoff
            } else if line.count >= 14, line.dropFirst(14).hasPrefix("  "), var d = old.date(from: "\(year)-" + line.prefix(14)) {
                if d > now.addingTimeInterval(86400) { d = old.date(from: "\(year - 1)-" + line.prefix(14)) ?? d }
                keep = d >= cutoff
            }
            if keep { out.append(line) }
        }
        var s = out.joined(separator: "\n")
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { s = "" }
        return s
    }

    /// 清空全部诊断日志。
    static func clear(completion: (() -> Void)? = nil) {
        queue.async {
            try? FileManager.default.removeItem(at: rotatedURL)
            try? FileManager.default.removeItem(at: url)
            if let completion { DispatchQueue.main.async(execute: completion) }
        }
    }

    /// 两个日志文件加起来的大小（字节）。
    static var size: Int {
        [url, rotatedURL].compactMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int }.reduce(0, +)
    }

    static func log(_ message: String) {
        let line = "\(formatter.string(from: Date()))  \(message)\n"
        queue.async {
            let fm = FileManager.default
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
                let old = rotatedURL
                try? fm.removeItem(at: old)
                try? fm.moveItem(at: url, to: old)
            }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(Data(line.utf8))
                try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
