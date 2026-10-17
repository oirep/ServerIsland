import Foundation

/// 本机记录的已结束任务（最近 24 小时）。集群没开 accounting、或者是直连服务器时，
/// "最近 24 小时"就用这里的记录。
@MainActor
final class HistoryStore {
    private var entries: [UUID: [HistoryEntry]] = [:]
    private let url = ConfigStore.directory.appendingPathComponent("history.json")
    private let window: TimeInterval = 24 * 3600

    init() {
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder.iso.decode([String: [HistoryEntry]].self, from: data) {
            for (k, v) in decoded { if let id = UUID(uuidString: k) { entries[id] = v } }
        }
        prune()
    }

    func record(_ host: UUID, _ entry: HistoryEntry) {
        var list = entries[host] ?? []
        list.removeAll { $0.id == entry.id }
        list.insert(entry, at: 0)
        entries[host] = Array(list.prefix(200))
        prune()
        save()
    }

    func entries(for host: UUID) -> [HistoryEntry] {
        let cutoff = Date().addingTimeInterval(-window)
        return (entries[host] ?? []).filter { $0.endedAt > cutoff }
    }

    private func prune() {
        let cutoff = Date().addingTimeInterval(-window)
        for (k, v) in entries { entries[k] = v.filter { $0.endedAt > cutoff } }
    }

    private func save() {
        let dict = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.uuidString, $0.value) })
        try? FileManager.default.createDirectory(at: ConfigStore.directory, withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(dict).write(to: url, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
