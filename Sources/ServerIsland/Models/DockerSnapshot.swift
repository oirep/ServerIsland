import Foundation

/// Docker 独立于作业列表，避免容器常驻运行触发计算任务完成提醒。
struct DockerSnapshot: Codable, Equatable {
    var containers: [DockerContainer] = []
    var total = 0
    var running = 0
    var truncated = false
    var sampleLimited = false
    var socket: String?
    var version: String?
    var error: String?
    var listedAt: Double?
    var listOnly: Bool?

    static func parse(_ lines: [String], previous: DockerSnapshot? = nil) -> DockerSnapshot {
        guard let text = lines.last(where: { $0.hasPrefix("{") }), let data = text.data(using: .utf8),
              var snapshot = try? JSONDecoder().decode(Self.self, from: data) else {
            return DockerSnapshot(error: lines.contains(where: { $0.contains("python3") && ($0.contains("not found") || $0.contains("未找到")) }) ? "python_missing" : "invalid_response")
        }
        // 全局采样的列表读取可能早于页面快刷新；保留最新成员与状态，仍接收更新的资源样本。
        if snapshot.error == nil, let time = snapshot.listedAt, let previous, let oldTime = previous.listedAt, time < oldTime {
            let samples = snapshot.containers
            snapshot.containers = previous.containers.map { current in
                guard let sample = samples.first(where: { $0.id == current.id && $0.state == current.state }),
                      (sample.sampledAt ?? 0) > (current.sampledAt ?? 0) else { return current }
                return sample.withListFields(from: current)
            }
            snapshot.total = previous.total; snapshot.running = previous.running
            snapshot.truncated = previous.truncated; snapshot.listedAt = previous.listedAt
        } else if snapshot.listOnly == true {
            // 列表快读不伪造资源采样，状态未变的运行容器继续展示上次的资源数值。
            snapshot.containers = snapshot.containers.map { item in
                guard let old = previous?.containers.first(where: { $0.id == item.id }) else { return item }
                if item.state == "running", old.state == item.state { return old.withListFields(from: item) }
                var changed = item
                changed.updatedAt = max(old.updatedAt ?? 0, item.state == old.state ? (item.updatedAt ?? 0) : (snapshot.listedAt ?? 0))
                return changed
            }
        }
        // 只有连续有效样本才显示速率；首次采集、计数回退、停止或重建时保持未知。
        for index in snapshot.containers.indices {
            let item = snapshot.containers[index]
            // 全局轮询可能比详情请求更早发出、却更晚返回，不能覆盖新采样。
            if let old = previous?.containers.first(where: { $0.id == item.id }),
               item.state == "running", old.state == "running",
               let oldTime = old.sampledAt, let newTime = item.sampledAt, oldTime > newTime {
                snapshot.containers[index] = old
                continue
            }
            if let oldTime = previous?.containers.first(where: { $0.id == item.id })?.updatedAt {
                snapshot.containers[index].updatedAt = max(item.updatedAt ?? item.createdAt ?? 0, oldTime)
            }
            guard item.state == "running", item.statsError == nil,
                  let old = previous?.containers.first(where: { $0.id == item.id && $0.state == "running" && $0.statsError == nil }),
                  let currentTime = item.sampledAt, let oldTime = old.sampledAt,
                  currentTime > oldTime else { continue }
            let seconds = currentTime - oldTime
            func rate(_ current: Double?, _ previous: Double?) -> Double? {
                guard let current, let previous, current >= previous else { return nil }
                return (current - previous) / seconds
            }
            snapshot.containers[index].rxRate = rate(item.networkRx, old.networkRx)
            snapshot.containers[index].txRate = rate(item.networkTx, old.networkTx)
            snapshot.containers[index].readRate = rate(item.blockRead, old.blockRead)
            snapshot.containers[index].writeRate = rate(item.blockWrite, old.blockWrite)
        }
        return snapshot
    }

    static func errorText(_ code: String) -> String {
        switch code {
        case "container_missing": return L("容器已移除或不可见", "Container was removed or is no longer visible")
        case "invalid_container": return L("容器标识无效或 Docker 监控已关闭", "Invalid container ID or Docker monitoring is disabled")
        case "permission_denied": return L("SSH 用户没有读取 Docker socket 的权限", "SSH user cannot access the Docker socket")
        case "socket_missing": return L("未找到 Docker socket", "Docker socket not found")
        case "python_missing": return L("服务器缺少 python3，无法采集 Docker 指标", "python3 is required on the server for Docker metrics")
        case "unsupported_endpoint": return L("DOCKER_HOST 需要使用 unix:// socket", "DOCKER_HOST must use a unix:// socket")
        case "timeout": return L("Docker 指标采集超时", "Docker metrics timed out")
        case "daemon_unavailable": return L("无法连接 Docker daemon", "Cannot connect to the Docker daemon")
        default: return L("Docker API 返回了无法识别的数据", "Unrecognized Docker API response")
        }
    }
}

struct DockerContainer: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var image: String
    var state: String
    var status: String
    var health: String
    var ports: [String]
    var composeProject: String
    var composeService: String
    var cpuPercent: Double?
    var onlineCPUs: Int?
    var memoryUsed: Double?
    var memoryLimit: Double?
    var networkRx: Double?
    var networkTx: Double?
    var blockRead: Double?
    var blockWrite: Double?
    var pids: Int?
    var sampledAt: Double?
    var statsError: String?
    var rxRate: Double?
    var txRate: Double?
    var readRate: Double?
    var writeRate: Double?
    var createdAt: Double?
    var updatedAt: Double?
    var cpuLimitCores: Double?
    var memoryConfiguredLimit: Double?
    var limitsRead: Bool?
    var limitsError: String?
    var cmd: [String]?
    var entrypoint: [String]?
    /// 列表元信息与资源采样独立合并，避免快刷新清空指标或慢采样回滚容器状态。
    func withListFields(from item: DockerContainer) -> DockerContainer {
        var result = self
        result.name = item.name; result.image = item.image; result.state = item.state
        result.status = item.status; result.health = item.health; result.ports = item.ports
        result.composeProject = item.composeProject; result.composeService = item.composeService
        result.createdAt = item.createdAt
        result.updatedAt = max(updatedAt ?? 0, item.updatedAt ?? item.createdAt ?? 0)
        return result
    }
    /// 暂停和重启中的容器仍属于活动组，其余非运行状态放入底部。
    var isStopped: Bool { !["running", "restarting", "paused"].contains(state) }
    var commandTitle: String { cmd?.isEmpty == false ? "CMD" : "ENTRYPOINT" }
    var commandArguments: [String]? { cmd?.isEmpty == false ? cmd : entrypoint }

    var memoryCapacity: Double? {
        [memoryConfiguredLimit, memoryLimit].compactMap { $0 }.filter { $0 > 0 }.min()
    }
    var memoryFraction: Double? {
        guard let memoryUsed, let capacity = memoryCapacity else { return nil }
        return min(1, max(0, memoryUsed / capacity))
    }
    /// 有硬限额时按容器容量计算；未设限则沿用 Docker 单核 100% 的口径。
    var cpuUsagePercent: Double? {
        cpuPercent.map { $0 / ((cpuLimitCores ?? 0) > 0 ? cpuLimitCores! : 1) }
    }
    var cpuFraction: Double? { cpuUsagePercent.map { min(1, max(0, $0 / 100)) } }
    /// 综合占用按 CPU 容量和内存上限的比例取较大值，避免不同量纲的绝对值混加。
    var resourceFraction: Double? { [cpuFraction, memoryFraction].compactMap { $0 }.max() }
    var stateLabel: String {
        switch state {
        case "running": return L("运行中", "Running")
        case "exited": return L("已停止", "Stopped")
        case "paused": return L("已暂停", "Paused")
        case "restarting": return L("重启中", "Restarting")
        case "created": return L("已创建", "Created")
        case "dead": return L("异常", "Dead")
        case "removing": return L("移除中", "Removing")
        default: return state
        }
    }
}
