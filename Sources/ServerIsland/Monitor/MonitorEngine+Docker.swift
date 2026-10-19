import Foundation

/// 当前页按目标间隔串行采集；请求较慢时不堆积，临时失败有界退避。
enum DockerLivePolling {
    static let interval: Double = 1
    static func delay(elapsed: Double, failures: Int, interval: Double = Self.interval) -> Double {
        failures > 0 ? min(15, pow(2, Double(min(failures, 4)))) : max(0.05, interval - elapsed)
    }
    static func retries(_ code: String?) -> Bool {
        !["needs_login", "invalid_container", "container_missing", "logs_unavailable", "unsupported_endpoint", "python_missing", "permission_denied", "socket_missing"].contains(code ?? "")
    }
}

struct DockerLiveResult {
    var message: String?
    var retry = true
}

extension MonitorEngine {
    /// 全部列表仅快读当前主机 Docker 状态；页面离开或进入详情时取消，不等待全局刷新。
    func monitorDockerList(host: HostConfig, interval: Double = DockerLivePolling.interval, onUpdate: (DockerLiveResult) -> Void) async {
        guard !demo, !IslandPreview.active else { return }
        var failures = 0
        while !Task.isCancelled {
            let started = Date()
            let result = await refreshDockerList(host: host)
            guard !Task.isCancelled else { return }
            onUpdate(result)
            failures = result.message == nil ? 0 : failures + 1
            guard result.retry else { return }
            do { try await Task.sleep(for: .seconds(DockerLivePolling.delay(elapsed: Date().timeIntervalSince(started), failures: failures, interval: interval))) }
            catch { return }
        }
    }

    func refreshDockerList(host: HostConfig, waitForCurrent: Bool = false) async -> DockerLiveResult {
        // 手动刷新等待现有快读完成后再读一次；自动刷新仍直接去重，不堆积请求。
        while waitForCurrent && dockerListRequests.contains(host.id) {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return DockerLiveResult(retry: false) }
        }
        guard !Task.isCancelled else { return DockerLiveResult(retry: false) }
        let host = store.host(host.id) ?? host
        guard host.enabled, host.showDocker else { return DockerLiveResult(message: DockerSnapshot.errorText("invalid_container"), retry: false) }
        guard dockerListRequests.insert(host.id).inserted else { return DockerLiveResult() }
        defer { dockerListRequests.remove(host.id) }
        let script = (host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n") + DockerMonitor.listScript
        let result: SSHResult
        if let dockerListReader { result = await dockerListReader(host, script) }
        else { result = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 12) }
        guard !Task.isCancelled else { return DockerLiveResult(retry: false) }
        guard let current = store.host(host.id), current.enabled, current.showDocker else {
            return DockerLiveResult(message: DockerSnapshot.errorText("invalid_container"), retry: false)
        }
        if let problem = SSHRunner.classify(result, host: host) {
            switch problem {
            case .needsLogin(let text): return DockerLiveResult(message: text, retry: false)
            case .error(let text): return DockerLiveResult(message: text)
            default: break
            }
        }
        let fresh = DockerSnapshot.parse(result.stdout.components(separatedBy: .newlines), previous: snapshots[host.id]?.docker)
        if let code = fresh.error { return DockerLiveResult(message: DockerSnapshot.errorText(code), retry: DockerLivePolling.retries(code)) }
        // 不改主机健康、资源、任务、lastUpdate 或 isRefreshing；仅替换 Docker 列表数据。
        var snapshot = snapshots[host.id] ?? HostSnapshot()
        snapshot.docker = fresh
        setSnapshot(snapshot, for: host.id)
        return DockerLiveResult()
    }

    /// 当前详情的采样生命周期由页面 task 管理，与全局后台循环分离。
    func monitorDockerDetail(host: HostConfig, container: String, onUpdate: (DockerLiveResult) -> Void) async {
        var failures = 0
        while !Task.isCancelled {
            let started = Date()
            let result = await refreshDockerDetail(host: host, container: container)
            guard !Task.isCancelled else { return }
            onUpdate(result)
            failures = result.message == nil ? 0 : failures + 1
            guard result.retry else { return }
            let delay = DockerLivePolling.delay(elapsed: Date().timeIntervalSince(started), failures: failures)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    /// 活跃详情独立于全局间隔，只采当前容器；页面取消后不再合并响应。
    func refreshDockerDetail(host: HostConfig, container: String) async -> DockerLiveResult {
        let host = store.host(host.id) ?? host
        guard host.enabled, host.showDocker, let command = DockerMonitor.detailScript(container: container) else {
            return DockerLiveResult(message: DockerSnapshot.errorText("invalid_container"), retry: false)
        }
        let key = host.id.uuidString + "|" + container
        guard dockerLiveRequests.insert(key).inserted else { return DockerLiveResult() }
        defer { dockerLiveRequests.remove(key) }
        let script = (host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n") + command
        let result: SSHResult
        if let dockerDetailReader { result = await dockerDetailReader(host, script) }
        else { result = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 12) }
        guard !Task.isCancelled else { return DockerLiveResult(retry: false) }
        guard let current = store.host(host.id), current.enabled, current.showDocker else {
            return DockerLiveResult(message: DockerSnapshot.errorText("invalid_container"), retry: false)
        }
        if let problem = SSHRunner.classify(result, host: host) {
            switch problem {
            case .needsLogin(let text): return DockerLiveResult(message: text, retry: false)
            case .error(let text): return DockerLiveResult(message: text)
            default: break
            }
        }
        let fresh = DockerSnapshot.parse(result.stdout.components(separatedBy: .newlines), previous: snapshots[host.id]?.docker)
        if let code = fresh.error {
            return DockerLiveResult(message: DockerSnapshot.errorText(code), retry: DockerLivePolling.retries(code))
        }
        if let code = fresh.containers.first?.statsError {
            return DockerLiveResult(message: DockerSnapshot.errorText(code), retry: DockerLivePolling.retries(code))
        }
        applyDockerDetail(fresh, host: host.id)
        return DockerLiveResult()
    }

    /// 只替换选中容器，不覆盖其它容器、主机资源或全局采集时刻。
    func applyDockerDetail(_ incoming: DockerSnapshot, host: UUID) {
        guard incoming.error == nil, incoming.containers.count == 1, let item = incoming.containers.first else { return }
        var snapshot = snapshots[host] ?? HostSnapshot()
        var docker = snapshot.docker ?? DockerSnapshot()
        if let index = docker.containers.firstIndex(where: { $0.id == item.id }) {
            let old = docker.containers[index]
            if let before = old.sampledAt, let after = item.sampledAt, before > after { return }
            docker.running = max(0, docker.running + (item.state == "running" ? 1 : 0) - (old.state == "running" ? 1 : 0))
            docker.containers[index] = item
        } else {
            docker.containers.append(item)
            docker.total = max(docker.total + 1, docker.containers.count)
            docker.running += item.state == "running" ? 1 : 0
        }
        docker.error = nil
        docker.socket = incoming.socket ?? docker.socket
        docker.version = incoming.version ?? docker.version
        dockerHistory.record(host: host, snapshot: docker)
        snapshot.docker = docker
        setSnapshot(snapshot, for: host)
    }

    /// 两个入口的布局独立保存；纯展示变更不重启 SSH 轮询。
    func setDockerView(host: UUID, mode: DockerViewMode? = nil, sort: DockerSortOrder? = nil, allContainers: Bool = false) {
        guard let index = store.settings.hosts.firstIndex(where: { $0.id == host }) else { return }
        if let mode {
            if allContainers { store.settings.hosts[index].dockerAllView = mode }
            else { store.settings.hosts[index].dockerView = mode }
        }
        if let sort { store.settings.hosts[index].dockerSort = sort }
        sync()
    }

    /// 收藏属于本机展示偏好，不改变容器或触发 SSH 采集。
    func toggleDockerFavorite(host: UUID, name: String) {
        guard let index = store.settings.hosts.firstIndex(where: { $0.id == host }) else { return }
        if store.settings.hosts[index].dockerFavorites.contains(name) {
            store.settings.hosts[index].dockerFavorites.removeAll { $0 == name }
        } else {
            store.settings.hosts[index].dockerFavorites.append(name)
        }
        sync()
    }

    /// 日志页短请求读取尾部，不保持 Docker follow 连接，也不保存运行日志。
    func fetchDockerLogs(host: HostConfig, container: String, tail: Int = 200) async -> DockerLogs {
        let host = store.host(host.id) ?? host
        guard host.enabled, host.showDocker, let command = DockerMonitor.logScript(container: container, tail: tail) else {
            return DockerLogs(error: "invalid_container")
        }
        let script = (host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n") + command
        let result = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 15)
        if let problem = SSHRunner.classify(result, host: host) {
            switch problem {
            case .needsLogin(let text): return DockerLogs(error: "needs_login", message: text)
            case .error(let text): return DockerLogs(error: "ssh", message: text)
            default: break
            }
        }
        guard let line = result.stdout.components(separatedBy: .newlines).last(where: { $0.hasPrefix("{") }),
              let data = line.data(using: .utf8), let logs = try? JSONDecoder().decode(DockerLogs.self, from: data) else {
            return DockerLogs(error: result.status == 127 ? "python_missing" : "invalid_response")
        }
        return logs
    }
}
