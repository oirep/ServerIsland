import AppKit

/// ssh 的 SSH_ASKPASS 助手：ssh 需要密码 / 动态口令 / 确认主机指纹时会启动本程序，
/// 把提示语作为第一个参数传进来；我们弹一个原生对话框，把用户输入写到 stdout 交给 ssh。
/// 密码默认不保存；用户勾选"记住密码"时只存进系统钥匙串，下次自动填上（动态口令从不保存）。
/// 经跳板机时，每一跳的 ssh 环境变量里带着那一跳的服务器 ID（见 SSHHosts），弹窗写明是哪台机器。
enum AskPass {
    static let envFlag = "SERVERISLAND_ASKPASS"
    static let envHost = "SERVERISLAND_ASKPASS_HOST"
    static let envHostID = "SERVERISLAND_ASKPASS_HOSTID"
    /// 一次登录的临时目录：记录哪台机器已经用过钥匙串里的密码（再被问就说明密码错了）、用户是否勾选记住。
    static let envSession = "SERVERISLAND_ASKPASS_SESSION"
    /// 后台自动重新登录：不弹任何窗口，只用钥匙串里的密码。
    static let envSilent = "SERVERISLAND_ASKPASS_SILENT"

    static var isAskPassInvocation: Bool {
        ProcessInfo.processInfo.environment[envFlag] == "1"
    }

    enum PromptKind: Equatable { case hostKey, passphrase, oneTimeCode, password, username, other }

    /// 按 ssh / 服务器给出的提示语判断要的是什么。
    static func kind(of prompt: String) -> PromptKind {
        let lower = prompt.lowercased()
        if lower.contains("yes/no") || lower.contains("fingerprint") { return .hostKey }
        if lower.contains("passphrase") { return .passphrase }
        if lower.contains("username") || lower.contains("user name") || lower.contains("用户名") { return .username }
        if ["code", "token", "otp", "verification", "authenticator", "验证码", "动态"].contains(where: lower.contains) { return .oneTimeCode }
        if lower.contains("password") || lower.contains("密码") { return .password }
        return .other
    }

    @MainActor
    static func run() -> Int32 {
        let env = ProcessInfo.processInfo.environment
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let hostConfig = env[envHostID].flatMap(UUID.init(uuidString:)).flatMap(loadHost)
        let host = hostConfig?.displayName ?? env[envHost] ?? L("服务器", "server")
        let session = env[envSession].map { URL(fileURLWithPath: $0) }
        let silent = env[envSilent] == "1"
        let kind = kind(of: prompt)
        let canRemember = kind == .password && hostConfig?.auth.canRemember == true

        // 先试钥匙串里记住的密码；同一次登录里再被问到，说明它已经不对了。
        var rejectedSaved = false
        if canRemember, let h = hostConfig, let session {
            let used = session.appendingPathComponent("used-" + h.id.uuidString)
            if FileManager.default.fileExists(atPath: used.path) {
                rejectedSaved = true
            } else if let saved = Keychain.password(for: h.id) {
                FileManager.default.createFile(atPath: used.path, contents: nil)
                print(saved)
                return 0
            }
        }
        if silent { return 1 }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.icon = NSImage(named: NSImage.applicationIconName)

        // 首次连接确认主机指纹
        if kind == .hostKey {
            alert.messageText = L("第一次连接 \(host)", "First connection to \(host)")
            alert.informativeText = prompt + L("\n\n确认这是你的服务器后再继续。", "\n\nContinue only if this is your server.")
            alert.addButton(withTitle: L("信任并继续", "Trust & Continue"))
            alert.addButton(withTitle: L("取消", "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return 1 }
            print("yes")
            return 0
        }

        alert.messageText = L("登录 \(host)", "Log in to \(host)")
        var info = prompt.isEmpty ? L("请输入密码", "Enter your password") : prompt
        if rejectedSaved {
            info = L("钥匙串里保存的密码没有通过，请重新输入。\n\n", "The saved password was rejected. Please enter it again.\n\n") + info
        }
        alert.informativeText = info + (canRemember
            ? L("\n\n只交给 ssh 用于登录；勾选“记住密码”时存进系统钥匙串。", "\n\nPassed to ssh to log in; stored in the system keychain only if you tick “Remember”.")
            : L("\n\n只会交给 ssh 用于这一次登录，ServerIsland 不会保存。", "\n\nPassed to ssh for this login only; ServerIsland never stores it."))
        let isSecret = kind != .username
        let field: NSTextField = isSecret ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                                          : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        switch kind {
        case .oneTimeCode: field.placeholderString = L("动态口令 / 验证码", "One-time code")
        case .passphrase: field.placeholderString = L("私钥口令", "Key passphrase")
        case .username: field.placeholderString = L("用户名", "Username")
        default: field.placeholderString = L("密码", "Password")
        }
        var remember: NSButton?
        if canRemember {
            let box = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54))
            field.frame.origin.y = 30
            box.addSubview(field)
            let check = NSButton(checkboxWithTitle: L("记住密码（存入钥匙串）", "Remember (in Keychain)"), target: nil, action: nil)
            check.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
            check.state = hostConfig?.rememberPassword == true ? .on : .off
            box.addSubview(check)
            remember = check
            alert.accessoryView = box
        } else {
            alert.accessoryView = field
        }
        alert.addButton(withTitle: L("登录", "Log In"))
        alert.addButton(withTitle: L("取消", "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return 1 }

        if let remember, let h = hostConfig {
            let on = remember.state == .on
            if on {
                Keychain.save(field.stringValue, for: h.id, label: h.displayName)
                // 刚输入的这次也算"用过"：若仍被拒，下次会重新弹窗而不是反复填错的密码。
                if let session { FileManager.default.createFile(atPath: session.appendingPathComponent("used-" + h.id.uuidString).path, contents: nil) }
            } else {
                Keychain.delete(h.id)
            }
            if let session {
                try? (on ? "1" : "0").write(to: session.appendingPathComponent("remember-" + h.id.uuidString), atomically: true, encoding: .utf8)
            }
        }
        print(field.stringValue)
        return 0
    }

    /// 直接读配置文件（askpass 是单独的进程，不启动 App 的其它部分）。
    @MainActor private static func loadHost(_ id: UUID) -> HostConfig? {
        guard let data = try? Data(contentsOf: ConfigStore.fileURL),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data) else { return nil }
        return settings.hosts.first { $0.id == id }
    }
}

struct LoginOutcome {
    /// nil 表示成功，否则是错误说明。
    var error: String?
    /// 弹窗里改了"记住密码"的机器（含跳板机）。
    var remember: [UUID: Bool] = [:]
}

extension SSHRunner {
    /// 用原生对话框登录：建立一条后台主连接并按设置时长保持，之后的轮询全部复用它。
    /// 经跳板机时，每一跳要密码都会单独弹窗（写明是哪台机器）。
    /// `silent`：后台自动重新登录，只用钥匙串里记住的密码，不弹任何窗口。
    static func loginWithPrompt(host: HostConfig, silent: Bool = false) async -> LoginOutcome {
        ensureControlDirectory()
        guard let exe = Bundle.main.executablePath else { return LoginOutcome(error: L("找不到程序路径", "Cannot find the app executable")) }
        let token = UUID().uuidString.prefix(8)
        let errFile = URL(fileURLWithPath: controlDirectory).appendingPathComponent("login-\(token).err")
        let session = URL(fileURLWithPath: controlDirectory).appendingPathComponent("askpass-\(token)")
        FileManager.default.createFile(atPath: errFile.path, contents: nil)
        try? FileManager.default.createDirectory(at: session, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer {
            try? FileManager.default.removeItem(at: errFile)
            try? FileManager.default.removeItem(at: session)
        }

        let (status, err) = await withCheckedContinuation { (continuation: CheckedContinuation<(Int32, String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                p.arguments = configArgs(host) + keepAliveOptions(host) + [
                    "-o", "ControlMaster=yes", "-o", "ControlPath=\(controlPath(for: host))",
                    "-o", "ConnectTimeout=15", "-o", "NumberOfPasswordPrompts=\(silent ? 1 : 2)",
                    "-o", "LogLevel=ERROR",
                    "-fN", target(host),
                ]
                var env = ProcessInfo.processInfo.environment
                env["SSH_ASKPASS"] = exe
                env["SSH_ASKPASS_REQUIRE"] = "force"
                env["DISPLAY"] = env["DISPLAY"] ?? ":0"
                env[AskPass.envFlag] = "1"
                env[AskPass.envHost] = host.displayName
                env[AskPass.envHostID] = host.id.uuidString
                env[AskPass.envSession] = session.path
                if silent { env[AskPass.envSilent] = "1" }
                p.environment = env
                // 后台主连接会继承 stdout/stderr：不能用管道（会一直读不到 EOF），改用文件。
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = try? FileHandle(forWritingTo: errFile)
                do { try p.run() } catch {
                    continuation.resume(returning: (-1, L("无法启动 ssh：", "Cannot start ssh: ") + error.localizedDescription)); return
                }
                // 用户输入口令需要时间（多跳时要输好几次），最多等 5 分钟。
                let deadline = Date().addingTimeInterval(silent ? 40 : 300)
                while p.isRunning && Date() < deadline { usleep(200_000) }
                if p.isRunning { p.terminate() }
                continuation.resume(returning: (p.terminationStatus, (try? String(contentsOf: errFile, encoding: .utf8)) ?? ""))
            }
        }

        var outcome = LoginOutcome()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: session.path) {
            for f in files where f.hasPrefix("remember-") {
                guard let id = UUID(uuidString: String(f.dropFirst("remember-".count))) else { continue }
                let v = (try? String(contentsOf: session.appendingPathComponent(f), encoding: .utf8)) ?? ""
                outcome.remember[id] = v.hasPrefix("1")
            }
        }
        if status != 0 {
            let line = err.components(separatedBy: .newlines).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            outcome.error = line ?? L("登录被取消或失败", "Login cancelled or failed")
            // 经跳板机时指明是哪一跳出的问题
            switch jumpProblem(err, host: host) {
            case .needsLogin(let m)?, .error(let m)?: outcome.error = m + (line.map { "（\($0)）" } ?? "")
            default: break
            }
        }
        return outcome
    }

    /// 主连接的保活参数：每 30 秒发心跳，连续 6 次没回应（约 3 分钟）才断开。
    static func keepAliveOptions(_ host: HostConfig) -> [String] {
        ["-o", "ControlPersist=\(host.keepAlive.controlPersist)",
         "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes"]
    }

    /// 主连接是否还活着。
    static func masterAlive(host: HostConfig) async -> Bool {
        let r = await runProcess("/usr/bin/ssh", args: configArgs(host) + ["-o", "ControlPath=\(controlPath(for: host))", "-O", "check", target(host)],
                                 stdin: nil, timeout: 5)
        return r.status == 0
    }
}
