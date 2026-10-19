import AppKit
import Foundation

enum DockerControlAction: String {
    case start, stop, restart
    var label: String {
        switch self {
        case .start: return L("启动", "Start")
        case .stop: return L("停止", "Stop")
        case .restart: return L("重启", "Restart")
        }
    }
}

struct DockerControlResult: Decodable {
    var ok: Bool
    var error: String?
}

/// 控制和只读采集使用分开的脚本，只有显式确认按钮才会触发写接口。
enum DockerControl {
    static var source: String {
        let file = Bundle.main.url(forResource: "docker-control", withExtension: "py")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("remote/docker-control.py")
        return (try? String(contentsOf: file, encoding: .utf8)) ?? "print('{\"ok\":false,\"error\":\"invalid_response\"}')\n"
    }
    static func script(container: String, action: DockerControlAction) -> String? {
        guard validID(container) else { return nil }
        return "SI_DOCKER_CONTROL_CONTAINER=" + SSHRunner.shellQuote(container)
            + " SI_DOCKER_CONTROL_ACTION=" + SSHRunner.shellQuote(action.rawValue)
            + " python3 - <<'SI_DOCKER_CONTROL_PY'\n" + source + "\nSI_DOCKER_CONTROL_PY"
    }
    static func validID(_ id: String) -> Bool { id.range(of: #"\A[a-fA-F0-9]{64}\z"#, options: .regularExpression) != nil }
    static func errorText(_ code: String) -> String {
        switch code {
        case "identity_changed": return L("容器标识已变化，未执行操作", "Container identity changed; no action taken")
        case "state_changed": return L("容器状态已变化，请刷新后重试", "Container state changed; refresh before trying again")
        case "control_unknown": return L("请求中断，操作结果待确认，请查看最新容器状态", "Request interrupted; check the latest container state to confirm the result")
        case "control_failed": return L("Docker 未能完成操作", "Docker could not complete the operation")
        case "invalid_control": return L("容器标识无效或操作未确认", "Invalid container ID or unconfirmed action")
        default: return DockerSnapshot.errorText(code)
        }
    }

    /// 使用系统 .command 文件默认关联打开，不指定任何终端应用。
    @MainActor
    static func openTerminal(host: HostConfig, container: String, socket: String?) -> String? {
        guard let script = terminalScript(host: host, container: container, socket: socket) else { return errorText("invalid_control") }
        return openScript(script)
    }

    @MainActor
    static func openLogsTerminal(host: HostConfig, container: String, socket: String?, tail: Int, showTimestamps: Bool = true) -> String? {
        guard let script = logsTerminalScript(host: host, container: container, socket: socket, tail: tail, showTimestamps: showTimestamps) else { return errorText("invalid_control") }
        return openScript(script)
    }

    @MainActor private static func openScript(_ script: String) -> String? {
        SSHRunner.ensureControlDirectory()
        let file = URL(fileURLWithPath: SSHRunner.controlDirectory).appendingPathComponent("container-" + UUID().uuidString + ".command")
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            return NSWorkspace.shared.open(file) ? nil : L("系统没有可打开 .command 的默认终端，请先设置默认打开应用", "No default app could open .command; configure your preferred terminal's file association")
        } catch { return error.localizedDescription }
    }

    static func terminalScript(host: HostConfig, container: String, socket: String?) -> String? {
        guard validID(container) else { return nil }
        let command = "exec docker exec -it " + SSHRunner.shellQuote(container) + " sh -c "
            + SSHRunner.shellQuote("if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi")
        return terminalScript(host: host, socket: socket, command: command)
    }

    /// tail 在点击时固化到启动脚本，不随页面之后的选择变化。
    static func logsTerminalScript(host: HostConfig, container: String, socket: String?, tail: Int, showTimestamps: Bool = true) -> String? {
        guard validID(container) else { return nil }
        let command = "exec docker logs " + (showTimestamps ? "--timestamps " : "")
            + "--follow --tail \(tail == 500 ? 500 : 200) " + SSHRunner.shellQuote(container)
        return terminalScript(host: host, socket: socket, command: command)
    }

    private static func terminalScript(host: HostConfig, socket: String?, command: String) -> String {
        var remote = host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n"
        if let socket, socket.hasPrefix("/") { remote += "export DOCKER_HOST=" + SSHRunner.shellQuote("unix://" + socket) + "\n" }
        remote += command
        let arguments = SSHRunner.configArgs(host) + ["-tt", "-o", "ControlMaster=auto", "-o", "ControlPath=" + SSHRunner.controlPath(for: host),
            "-o", "ControlPersist=15m", SSHRunner.target(host), "bash -l -c " + SSHRunner.shellQuote(remote)]
        return "#!/bin/bash\nexec /usr/bin/ssh " + arguments.map(SSHRunner.shellQuote).joined(separator: " ") + "\n"
    }
}

extension MonitorEngine {
    /// 确认是必填参数，防止采样、页面重绘或重试路径隐式执行控制命令。
    func controlDocker(host: HostConfig, container: String, action: DockerControlAction, confirmed: Bool) async -> String? {
        guard confirmed, let host = store.host(host.id), host.enabled, host.showDocker,
              let command = DockerControl.script(container: container, action: action) else { return DockerControl.errorText("invalid_control") }
        let key = host.id.uuidString + "|" + container
        guard dockerControlRequests.insert(key).inserted else { return L("容器操作正在执行", "A container operation is already in progress") }
        defer { dockerControlRequests.remove(key) }
        let script = (host.commands.preamble.isEmpty ? "" : host.commands.preamble + "\n") + command
        let result = await SSHRunner.run(host: host, remoteCommand: host.commands.shell, script: script, timeout: 40)
        if let problem = SSHRunner.classify(result, host: host) {
            switch problem {
            case .needsLogin(let text): return text
            case .error: return DockerControl.errorText("control_unknown")
            default: break
            }
        }
        guard let line = result.stdout.components(separatedBy: .newlines).last(where: { $0.hasPrefix("{") }),
              let response = try? JSONDecoder().decode(DockerControlResult.self, from: Data(line.utf8)) else {
            return DockerControl.errorText("control_unknown")
        }
        return response.ok ? nil : DockerControl.errorText(response.error ?? "control_failed")
    }
}
