import AppKit
import Foundation

struct SSHResult {
    var stdout: String
    var stderr: String
    var status: Int32
    var duration: TimeInterval
    var timedOut: Bool
}

/// 调用系统 `/usr/bin/ssh`。这样 `~/.ssh/config` 中的 ProxyJump、IdentityFile、
/// ssh-agent 等设置全部自动生效。默认启用 ControlMaster 连接复用：
/// 只有第一次需要握手，之后的轮询只是在已有连接上开一个新通道。
enum SSHRunner {
    /// Unix socket 路径有 104 字节上限，所以放在短路径下。
    static let controlDirectory = "/tmp/serverisland-\(getuid())"
    static var controlPath: String { controlDirectory + "/%C" }

    static func ensureControlDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: controlDirectory) {
            try? fm.createDirectory(atPath: controlDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    static func options(for host: HostConfig, connectTimeout: Int = 10) -> [String] {
        var opts = [
            "-o", "BatchMode=yes",              // 绝不在后台卡住等待密码输入
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "-T",
        ]
        if host.reuseConnection || host.auth == .interactive {
            ensureControlDirectory()
            // 免密主机：自动建立并保持主连接；需要密码的主机：只复用用户在终端里建立的主连接。
            let master = host.auth == .key ? "auto" : "no"
            opts += ["-o", "ControlMaster=\(master)", "-o", "ControlPath=\(controlPath)", "-o", "ControlPersist=15m"]
        }
        return opts
    }

    /// 在远端执行 `remoteCommand`，把 `script` 通过 stdin 传过去。
    static func run(host: HostConfig, remoteCommand: String, script: String?, timeout: TimeInterval = 30) async -> SSHResult {
        let args = options(for: host) + [host.alias, remoteCommand]
        let full = script.map { (host.importShellPath ? pathPrelude : "") + $0 }
        return await runProcess("/usr/bin/ssh", args: args, stdin: full, timeout: timeout)
    }

    /// 非交互 shell 不会执行 ~/.bashrc 里 `case $- in *i*)` 之后的内容（Ubuntu 默认如此），
    /// 所以装在家目录下的 Slurm / GPUMD 等常常"找不到命令"。这里把 rc 文件里 PATH= 行中
    /// 实际存在的目录追加到 PATH 末尾（只追加、不覆盖，含其它变量的条目跳过），不启动交互式 shell。
    static let pathPrelude = #"""
    for SI_D in $(grep -hE '^[[:space:]]*(export[[:space:]]+)?PATH=' ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc 2>/dev/null \
        | sed -E 's/^[[:space:]]*(export[[:space:]]+)?PATH=//; s/[;#].*$//; s/["'"'"']//g' | tr ':' '\n' \
        | sed -e "s#^~#$HOME#" -e "s#\$HOME#$HOME#g" -e "s#\${HOME}#$HOME#g" | grep -v '\$') /opt/slurm/bin /usr/local/slurm/bin; do
      case ":$PATH:" in *":$SI_D:"*) ;; *) [ -d "$SI_D" ] && PATH="$PATH:$SI_D" ;; esac
    done; export PATH; unset SI_D

    """#

    static func runProcess(_ path: String, args: [String], stdin: String?, timeout: TimeInterval) async -> SSHResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let start = Date()
                let process = Process()
                process.executableURL = URL(fileURLWithPath: path)
                process.arguments = args
                var env = ProcessInfo.processInfo.environment
                env["LC_ALL"] = "C"
                process.environment = env

                let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = inPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: SSHResult(stdout: "", stderr: L("无法启动 ssh：", "Cannot start ssh: ") + error.localizedDescription,
                                                             status: -1, duration: 0, timedOut: false))
                    return
                }

                // 分别在后台线程读取 stdout / stderr，避免管道缓冲区写满导致死锁。
                let outBox = DataBox(), errBox = DataBox()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    outBox.data = outPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    errBox.data = errPipe.fileHandleForReading.readDataToEndOfFile(); group.leave()
                }

                if let stdin, let data = stdin.data(using: .utf8) {
                    try? inPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? inPipe.fileHandleForWriting.close()

                var timedOut = false
                let timer = DispatchWorkItem {
                    if process.isRunning { timedOut = true; process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

                process.waitUntilExit()
                timer.cancel()
                group.wait()

                continuation.resume(returning: SSHResult(
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self),
                    status: process.terminationStatus,
                    duration: Date().timeIntervalSince(start),
                    timedOut: timedOut))
            }
        }
    }

    /// 把 ssh 自身的错误（退出码 255）翻译成用户能看懂的状态。
    static func classify(_ result: SSHResult, host: HostConfig) -> HostHealth? {
        if result.timedOut { return .error(L("连接超时", "Connection timed out")) }
        guard result.status == 255 else { return nil }
        let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = err.lowercased()
        if lower.contains("host key verification failed") {
            return .needsLogin(L("首次连接需要确认主机指纹", "Confirm the host key on first connection"))
        }
        if lower.contains("permission denied") || lower.contains("too many authentication")
            || lower.contains("keyboard-interactive") || lower.contains("control socket") && host.auth == .interactive {
            return .needsLogin(host.auth == .interactive ? L("需要登录", "Login required") : L("密钥登录失败", "Key login failed"))
        }
        if host.auth == .interactive && (lower.contains("no such file") || lower.isEmpty) {
            return .needsLogin(L("需要登录", "Login required"))
        }
        if lower.contains("could not resolve") { return .error(L("无法解析主机名", "Cannot resolve host name")) }
        if lower.contains("connection refused") { return .error(L("连接被拒绝", "Connection refused")) }
        if lower.contains("timed out") { return .error(L("连接超时", "Connection timed out")) }
        if lower.contains("no route") || lower.contains("network is unreachable") { return .error(L("网络不可达", "Network unreachable")) }
        let firstLine = err.components(separatedBy: .newlines).last { !$0.isEmpty } ?? L("ssh 连接失败", "ssh connection failed")
        return .error(firstLine)
    }

    /// 在"终端"里打开一次交互式登录，验证成功后主连接转入后台并保持 8 小时，
    /// 之后 App 的轮询都复用这条连接。App 本身不接触密码。
    static func openLoginInTerminal(host: HostConfig) {
        ensureControlDirectory()
        let safeName = host.alias.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let file = URL(fileURLWithPath: controlDirectory).appendingPathComponent("login-\(safeName).command")
        let alias = shellQuote(host.alias)
        let script = """
        #!/bin/bash
        clear
        echo "ServerIsland · \(L("登录", "Log in to")) \(host.displayName)"
        echo "\(L("验证成功后连接会在后台保持（\(host.keepAlive.label)），ServerIsland 将复用它查询状态。", "After you log in, the connection is kept for \(host.keepAlive.label) and reused by ServerIsland."))"
        echo
        if ssh \(keepAliveOptions(host).joined(separator: " ")) -o ControlMaster=yes -o ControlPath='\(controlPath)' -fN \(alias); then
          echo; echo "✓ \(L("已连接，可以关闭这个窗口。", "Connected. You can close this window."))"
        else
          echo; echo "✗ \(L("登录失败。", "Login failed."))"
        fi
        """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSLog("ServerIsland: cannot create login script: \(error)")
        }
    }

    /// 在终端里 ssh 到某个目录（详情页"在终端中打开"）。目录来自服务器返回的数据，用单引号转义。
    static func openShellInTerminal(host: HostConfig, directory: String) {
        ensureControlDirectory()
        let file = URL(fileURLWithPath: controlDirectory).appendingPathComponent("shell-\(UUID().uuidString.prefix(8)).command")
        let remote = "cd " + shellQuote(directory) + " && exec $SHELL -l"
        let script = """
        #!/bin/bash
        exec ssh -t -o ControlPath='\(controlPath)' \(shellQuote(host.alias)) \(shellQuote(remote))
        """
        do {
            try script.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSLog("ServerIsland: cannot create shell script: \(error)")
        }
    }

    /// 关闭复用的主连接。
    static func closeMaster(host: HostConfig) async {
        _ = await runProcess("/usr/bin/ssh", args: ["-o", "ControlPath=\(controlPath)", "-O", "exit", host.alias],
                             stdin: nil, timeout: 5)
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// 在线程间传递读取结果（由 DispatchGroup 保证先写后读）。
private final class DataBox: @unchecked Sendable {
    var data = Data()
}
