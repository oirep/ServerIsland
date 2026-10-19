import Foundation

/// 卡片与全部容器共用排序定义，资源采样不会被误认为容器更新时间。
enum DockerViewMode: String, Codable, CaseIterable { case list, grid }

enum DockerSortOrder: String, Codable, CaseIterable {
    case updated, resources, cpu, memory
    var label: String {
        switch self {
        case .updated: return L("最新更新", "Recently Updated")
        case .resources: return L("资源占用", "Resource Usage")
        case .cpu: return L("CPU 占用", "CPU Usage")
        case .memory: return L("内存占用", "Memory Usage")
        }
    }
    func sorted(_ containers: [DockerContainer], favorites: Set<String> = []) -> [DockerContainer] {
        func score(_ item: DockerContainer) -> Double {
            switch self {
            case .updated: return item.updatedAt ?? item.createdAt ?? -1
            case .resources: return item.resourceFraction ?? -1
            case .cpu: return item.cpuUsagePercent ?? -1
            case .memory: return item.memoryFraction ?? -1
            }
        }
        return containers.sorted {
            let aFavorite = favorites.contains($0.name), bFavorite = favorites.contains($1.name)
            if aFavorite != bFavorite { return aFavorite }
            if $0.isStopped != $1.isStopped { return !$0.isStopped }
            let a = score($0), b = score($1)
            if a != b { return a > b }
            let aTime = $0.updatedAt ?? $0.createdAt ?? -1, bTime = $1.updatedAt ?? $1.createdAt ?? -1
            if aTime != bTime { return aTime > bTime }
            return $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
    }
}

/// 仅保留 App 运行期间的实际采样，固定上限避免常驻监控无限占用内存。
struct DockerMetricPoint: Equatable, Identifiable {
    var id: Double { time }
    var time: Double
    var cpu: Double?
    var memory: Double?
    var rx: Double?
    var tx: Double?
    var read: Double?
    var write: Double?
}

struct DockerHistory {
    static let maxPoints = 600
    static let retention: Double = 6 * 3600
    private(set) var hosts: [UUID: [String: [DockerMetricPoint]]] = [:]

    mutating func record(host: UUID, snapshot: DockerSnapshot, now: Date = Date()) {
        guard snapshot.error == nil else { return }
        let cutoff = now.timeIntervalSince1970 - Self.retention
        var history = hosts[host] ?? [:]
        for id in Array(history.keys) {
            history[id] = history[id]?.filter { $0.time >= cutoff }
            if history[id]?.isEmpty == true { history[id] = nil }
        }
        for item in snapshot.containers {
            guard let time = item.sampledAt, time >= cutoff, item.statsError == nil, item.state == "running" else { continue }
            var points = history[item.id] ?? []
            guard points.last.map({ time > $0.time }) ?? true else { continue }
            points.append(DockerMetricPoint(time: time, cpu: item.cpuUsagePercent, memory: item.memoryUsed,
                                            rx: item.rxRate, tx: item.txRate, read: item.readRate, write: item.writeRate))
            history[item.id] = Array(points.suffix(Self.maxPoints))
        }
        // 重建后的新 ID 从新时间线开始，不拼接已移除容器的数据。
        let ids = Set(snapshot.containers.map(\.id))
        hosts[host] = history.filter { ids.contains($0.key) }
    }
    func points(host: UUID, container: String) -> [DockerMetricPoint] { hosts[host]?[container] ?? [] }
}

struct DockerLogs: Decodable, Equatable {
    var text = ""
    var truncated = false
    var fetchedAt: Double?
    var error: String?
    var message: String?
}
