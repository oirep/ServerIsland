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

    /// 每台机器的主连接 socket。手动填写 / 经跳板机的机器在 %C 前加上自己 ID 的前 8 位：
    /// 不同跳板机后面的两台服务器可能是同一个内网地址（%C 只按地址、端口、用户算，会撞在一起）。
    static func controlPath(for host: HostConfig) -> String {
        SSHHosts.needsPrivateConfig(host) ? controlDirectory + "/" + host.id.uuidString.prefix(8).lowercased() + "-%C" : controlPath
    }

    static func ensureControlDirectory() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: controlDirectory) {
            try? fm.createDirectory(atPath: controlDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        }
    }

    /// 手动填写 / 经跳板机的服务器要用 App 的私有 ssh 配置（见 SSHHosts）。
    static func configArgs(_ host: HostConfig) -> [String] {
        guard SSHHosts.needsPrivateConfig(host) else { return [] }
        SSHHosts.ensureWritten()
        return ["-F", SSHHosts.configPath]
    }

    /// ssh 命令行上的目标（别名或 si-<UUID>）。
    static func target(_ host: HostConfig) -> String { SSHHosts.target(host) }

    static func options(for host: HostConfig, connectTimeout: Int = 10) -> [String] {
        var opts = configArgs(host) + [
            "-o", "BatchMode=yes",              // 绝不在后台卡住等待密码输入
            "-o", "ConnectTimeout=\(connectTimeout)",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "-T",
        ]
        if host.reuseConnection || host.auth.needsLogin {
            ensureControlDirectory()
            // 免密主机：自动建立并保持主连接；需要密码的主机：只复用登录时建立的主连接。
            let master = host.auth == .key ? "auto" : "no"
            opts += ["-o", "ControlMaster=\(master)", "-o", "ControlPath=\(controlPath(for: host))", "-o", "ControlPersist=15m"]
        }
        return opts
    }

    /// 在远端执行 `remoteCommand`，把 `script` 通过 stdin 传过去。
    static func run(host: HostConfig, remoteCommand: String, script: String?, timeout: TimeInterval = 30) async -> SSHResult {
        let args = options(for: host) + [target(host), remoteCommand]
        let full = script.map { (host.importShellPath ? pathPrelude : "") + $0 }
        var result = await runProcess("/usr/bin/ssh", args: args, stdin: full, timeout: timeout)
        // 开着 ControlPersist 时，OpenSSH 把 ProxyCommand（跳板机那一跳）的 stderr 丢到 /dev/null，
        // 跳板机出错时什么提示都没有。这时不复用连接再试一次（只握手、不执行脚本），拿到真正的错误信息。
        if result.status == 255 && !result.timedOut && result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !SSHHosts.jumpChain(host).isEmpty {
            let probe = configArgs(host) + ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR",
                                            "-o", "ControlMaster=no", "-o", "ControlPath=none", "-T", target(host), "true"]
            let r = await runProcess("/usr/bin/ssh", args: probe, stdin: nil, timeout: 20)
            if r.status != 0 { result.stderr = r.stderr }
        }
        return result
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
        if let hop = jumpProblem(err, host: host) { return hop }
        if lower.contains("permission denied") || lower.contains("too many authentication")
            || lower.contains("keyboard-interactive") || lower.contains("control socket") && host.auth.needsLogin {
            if host.auth.needsLogin { return .needsLogin(L("需要登录", "Login required")) }
            return .needsLogin(keyPermissionHint(err) ?? keyFailureHint(lower))
        }
        if host.auth.needsLogin && (lower.contains("no such file") || lower.isEmpty) {
            return .needsLogin(L("需要登录", "Login required"))
        }
        if lower.contains("could not resolve") { return .error(L("无法解析主机名", "Cannot resolve host name")) }
        if lower.contains("connection refused") { return .error(L("连接被拒绝", "Connection refused")) }
        if lower.contains("timed out") { return .error(L("连接超时", "Connection timed out")) }
        if lower.contains("no route") || lower.contains("network is unreachable") { return .error(L("网络不可达", "Network unreachable")) }
        let firstLine = err.components(separatedBy: .newlines).last { !$0.isEmpty } ?? L("ssh 连接失败", "ssh connection failed")
        return .error(firstLine)
    }

    /// 私钥文件别人也能读（比如 0755）时 ssh 会直接忽略它（"Load key …: bad permissions"），再退到别的认证方式，
    /// 最后报的 Permission denied 容易被误认成密钥不对，所以单独指出来。
    static func keyPermissionHint(_ err: String) -> String? {
        guard let r = err.range(of: #"Load key "[^"]+": bad permissions"#, options: .regularExpression) else { return nil }
        let path = (String(err[r].dropFirst("Load key \"".count).prefix { $0 != "\"" }) as NSString).abbreviatingWithTildeInPath
        return L("私钥文件权限太宽，ssh 不肯用：在终端运行 chmod 600 \(path)",
                 "The private key is readable by others, so ssh ignores it: run chmod 600 \(path) in Terminal")
    }

    /// 密钥登录被拒时，根据服务器列出的认证方式给出建议。
    /// `Permission denied (password).` 这类不含 publickey 的列表说明密钥已经通过（partial success），还差密码。
    static func keyFailureHint(_ lower: String) -> String {
        guard let r = lower.range(of: #"permission denied \(([^)]*)\)"#, options: .regularExpression) else {
            return L("密钥登录失败", "Key login failed")
        }
        let methods = lower[r].split(whereSeparator: { "(),. ".contains($0) }).map(String.init)
        let wantsPassword = methods.contains("password") || methods.contains("keyboard-interactive")
        if wantsPassword && !methods.contains("publickey") {
            return L("密钥已通过，服务器还要求密码：认证方式请选“密钥 + 密码”", "Key accepted, but the server also wants a password: choose “Key + password”")
        }
        if wantsPassword {
            return L("密钥登录失败（服务器也接受密码，可改用“密码”登录）", "Key login failed (the server also accepts a password: try “Password”)")
        }
        return L("密钥登录失败", "Key login failed")
    }

    /// 经跳板机时，判断是不是某一跳出了问题，并指明是哪一跳。
    static func jumpProblem(_ err: String, host: HostConfig) -> HostHealth? {
        let chain = SSHHosts.jumpChain(host)
        guard !chain.isEmpty else { return nil }
        let lower = err.lowercased()
        // 跳板机本身登录成功，但它连不上目标
        if lower.contains("stdio forwarding failed") || lower.contains("open failed") || lower.contains("administratively prohibited") {
            return .error(L("跳板机“\(chain[0].displayName)”连不上这台服务器", "Jump host “\(chain[0].displayName)” cannot reach this server"))
        }
        // 错误信息里带着某一跳的地址
        for (i, hop) in chain.enumerated().reversed() {
            let names = hopNames(hop)
            guard err.split(separator: "\n").contains(where: { line in
                let l = line.lowercased()
                return names.contains { l.contains("@" + $0 + ":") || l.contains("to " + $0 + " ") || l.contains("host " + $0 + " ") || l.contains("resolve hostname " + $0) }
            }) else { continue }
            let what = i == 0 ? L("跳板机", "Jump host") : L("第 \(i + 1) 级跳板机", "Jump host #\(i + 1)")
            if lower.contains("permission denied") || lower.contains("too many authentication") {
                return .needsLogin(hop.auth.needsLogin
                    ? L("\(what)“\(hop.displayName)”需要登录", "\(what) “\(hop.displayName)” needs login")
                    : L("\(what)“\(hop.displayName)”：\(keyFailureHint(lower))", "\(what) “\(hop.displayName)”: \(keyFailureHint(lower))"))
            }
            if lower.contains("host key verification failed") {
                return .needsLogin(L("\(what)“\(hop.displayName)”需要确认主机指纹", "Confirm the host key of \(what.lowercased()) “\(hop.displayName)”"))
            }
            return .error(L("\(what)“\(hop.displayName)”连接失败", "\(what) “\(hop.displayName)” unreachable"))
        }
        if lower.contains("kex_exchange_identification") || lower.contains("connection closed by unknown")
            || lower.contains("closed by remote host") && !lower.contains("@") {
            return .error(L("经跳板机“\(chain[0].displayName)”连接失败", "Connection via jump host “\(chain[0].displayName)” failed"))
        }
        return nil
    }

    /// 错误信息里可能出现的地址：别名、HostName。
    private static func hopNames(_ hop: HostConfig) -> [String] {
        var names: [String] = []
        if hop.isManual {
            var h = hop.hostName.trimmingCharacters(in: .whitespaces).lowercased()
            if let at = h.lastIndex(of: "@") { h = String(h[h.index(after: at)...]) }
            names.append(h)
        } else {
            var a = hop.alias.lowercased()
            if let at = a.lastIndex(of: "@") { a = String(a[a.index(after: at)...]) }
            names.append(a)
            if let e = SSHConfigParser.load().first(where: { $0.alias == hop.alias }), let hn = e.hostName { names.append(hn.lowercased()) }
        }
        return names.filter { !$0.isEmpty }
    }

    /// 在"终端"里打开一次交互式登录，验证成功后主连接转入后台并保持 8 小时，
    /// 之后 App 的轮询都复用这条连接。App 本身不接触密码。
    static func openLoginInTerminal(host: HostConfig) {
        ensureControlDirectory()
        let safeName = host.alias.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
        let file = URL(fileURLWithPath: controlDirectory).appendingPathComponent("login-\(safeName).command")
        let alias = (configArgs(host).map(shellQuote) + [shellQuote(target(host))]).joined(separator: " ")
        let script = """
        #!/bin/bash
        clear
        echo "ServerIsland · \(L("登录", "Log in to")) \(host.displayName)"
        echo "\(L("验证成功后连接会在后台保持（\(host.keepAlive.label)），ServerIsland 将复用它查询状态。", "After you log in, the connection is kept for \(host.keepAlive.label) and reused by ServerIsland."))"
        echo
        if ssh \(keepAliveOptions(host).joined(separator: " ")) -o ControlMaster=yes -o ControlPath='\(controlPath(for: host))' -fN \(alias); then
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

    /// 在终端里 ssh 到某个目录（详情页"在终端中打开"）；directory 为 nil 时直接登录（卡片上的终端按钮）。
    /// 目录来自服务器返回的数据，用单引号转义。主连接还在时直接复用，不用再输密码。
    static func openShellInTerminal(host: HostConfig, directory: String? = nil) {
        ensureControlDirectory()
        let file = URL(fileURLWithPath: controlDirectory).appendingPathComponent("shell-\(UUID().uuidString.prefix(8)).command")
        do {
            try shellScript(host: host, directory: directory).write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            NSWorkspace.shared.open(file)
        } catch {
            NSLog("ServerIsland: cannot create shell script: \(error)")
        }
    }

    /// 终端打开 .command 时会先打印"路径 ; exit;"这一行：清屏盖掉它，窗口标题换成服务器名，脚本用完就删。
    static func shellScript(host: HostConfig, directory: String?) -> String {
        let remote = directory.map { " " + shellQuote("cd " + shellQuote($0) + " && exec $SHELL -l") } ?? ""
        let title = "ServerIsland · " + host.displayName + (directory.map { " · " + $0 } ?? "")
        return """
        #!/bin/bash
        clear
        printf '\\033]0;%s\\007' \(shellQuote(title))
        echo \(shellQuote("ServerIsland → " + host.displayName + (directory.map { "（\($0)）" } ?? "")))
        rm -f "$0"
        exec ssh \(configArgs(host).map(shellQuote).joined(separator: " ")) -t -o ControlPath='\(controlPath(for: host))' \(shellQuote(target(host)))\(remote)

        """
    }

    /// 关闭复用的主连接。
    static func closeMaster(host: HostConfig) async {
        _ = await runProcess("/usr/bin/ssh", args: configArgs(host) + ["-o", "ControlPath=\(controlPath(for: host))", "-O", "exit", target(host)],
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
