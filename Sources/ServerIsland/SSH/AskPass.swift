import AppKit

/// ssh 的 SSH_ASKPASS 助手：ssh 需要密码 / 动态口令 / 确认主机指纹时会启动本程序，
/// 把提示语作为第一个参数传进来；我们弹一个原生对话框，把用户输入写到 stdout 交给 ssh。
/// 输入内容只经过这一次管道，ServerIsland 不保存、不记录。
enum AskPass {
    static let envFlag = "SERVERISLAND_ASKPASS"
    static let envHost = "SERVERISLAND_ASKPASS_HOST"

    static var isAskPassInvocation: Bool {
        ProcessInfo.processInfo.environment[envFlag] == "1"
    }

    @MainActor
    static func run() -> Int32 {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let host = ProcessInfo.processInfo.environment[envHost] ?? L("服务器", "server")
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let lower = prompt.lowercased()
        let alert = NSAlert()
        alert.icon = NSImage(named: NSImage.applicationIconName)

        // 首次连接确认主机指纹
        if lower.contains("yes/no") || lower.contains("fingerprint") {
            alert.messageText = L("第一次连接 \(host)", "First connection to \(host)")
            alert.informativeText = prompt + L("\n\n确认这是你的服务器后再继续。", "\n\nContinue only if this is your server.")
            alert.addButton(withTitle: L("信任并继续", "Trust & Continue"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
            print("yes")
            return 0
        }

        let isSecret = !(lower.contains("username") || lower.contains("user name") || lower.contains("用户名"))
        alert.messageText = L("登录 \(host)", "Log in to \(host)")
        alert.informativeText = (prompt.isEmpty ? L("请输入密码", "Enter your password") : prompt)
            + L("\n\n只会交给 ssh 用于这一次登录，ServerIsland 不会保存。", "\n\nPassed to ssh for this login only; ServerIsland never stores it.")
        let field: NSTextField = isSecret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                                          : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = lower.contains("code") || lower.contains("token") || lower.contains("otp")
            || lower.contains("验证码") || lower.contains("动态") ? L("动态口令 / 验证码", "One-time code") : L("密码", "Password")
        alert.accessoryView = field
        alert.addButton(withTitle: L("登录", "Log In"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
        print(field.stringValue)
        return 0
    }
}

extension SSHRunner {
    /// 用原生对话框登录（适合每次密码都不同的动态口令集群）：建立一条后台主连接并按设置时长保持，
    /// 之后的轮询全部复用它。返回 nil 表示成功，否则是错误说明。
    static func loginWithPrompt(host: HostConfig) async -> String? {
        ensureControlDirectory()
        guard let exe = Bundle.main.executablePath else { return L("找不到程序路径", "Cannot find the app executable") }
        let errFile = URL(fileURLWithPath: controlDirectory).appendingPathComponent("login-\(UUID().uuidString.prefix(6)).err")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = keepAliveOptions(host) + [
                    "-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath)",
                    "-o", "ConnectTimeout=15", "-o", "NumberOfPasswordPrompts=1",
                    "-fN", host.alias,
                ]
                var env = ProcessInfo.processInfo.environment
                env["SSH_ASKPASS"] = exe
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
                env[AskPass.envFlag] = "1"
                env[AskPass.envHost] = host.displayName
                p.environment = env
                // 后台主连接会继承 stdout/stderr：不能用管道（会一直读不到 EOF），改用文件。
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = try? FileHandle(forWritingTo: errFile)
                do { try p.run() } catch {
                    continuation.resume(returning: L("无法启动 ssh：", "Cannot start ssh: ") + error.localizedDescription); return
                }
                // 用户输入口令需要时间，最多等 3 分钟。
                let deadline = Date().addingTimeInterval(180)
                while p.isRunning && Date() < deadline { usleep(200_000) }
                if p.isRunning { p.terminate() }
                let err = (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: errFile)
                if p.terminationStatus == 0 {
                    continuation.resume(returning: nil)
                } else {
                    let line = err.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    continuation.resume(returning: line ?? L("登录被取消或失败", "Login cancelled or failed"))
                }
            }
        }
    }

    /// 主连接的保活参数：每 30 秒发心跳，连续 6 次没回应（约 3 分钟）才断开。
    static func keepAliveOptions(_ host: HostConfig) -> [String] {
        ["-o", "ControlPersist=\(host.keepAlive.controlPersist)",
         "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes"]
    }

    /// 主连接是否还活着。
    static func masterAlive(host: HostConfig) async -> Bool {
        let r = await runProcess("/usr/bin/ssh", args: ["-o", "ControlPath=\(controlPath)", "-O", "check", host.alias],
                                 stdin: nil, timeout: 5)
        return r.status == 0
    }
}
