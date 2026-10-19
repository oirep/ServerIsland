import Foundation

/// 两端共享同一个采集文件，直接经现有 SSH stdin 发送，不在服务器安装脚本。
enum DockerMonitor {
    static var source: String {
        let bundled = Bundle.main.url(forResource: "docker-monitor", withExtension: "py")
        let development = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("remote/docker-monitor.py")
        return (try? String(contentsOf: bundled ?? development, encoding: .utf8)) ?? "print('{\"error\":\"invalid_response\",\"containers\":[],\"total\":0,\"running\":0,\"truncated\":false,\"sampleLimited\":false}')\n"
    }
    static var script: String { "python3 - <<'SI_DOCKER_PY'\n" + source + "\nSI_DOCKER_PY" }
    static var listScript: String { "SI_DOCKER_LIST_ONLY=1 " + script }

    static func logScript(container: String, tail: Int) -> String? {
        guard container.range(of: #"\A[a-fA-F0-9]{12,64}\z"#, options: .regularExpression) != nil else { return nil }
        return "SI_DOCKER_LOG_CONTAINER=" + SSHRunner.shellQuote(container) + " SI_DOCKER_LOG_TAIL=\(tail == 500 ? 500 : 200) " + script
    }

    static func detailScript(container: String) -> String? {
        guard container.range(of: #"\A[a-fA-F0-9]{12,64}\z"#, options: .regularExpression) != nil else { return nil }
        return "SI_DOCKER_DETAIL_CONTAINER=" + SSHRunner.shellQuote(container) + " " + script
    }
}
