import Foundation

/// 自检：认证方式、手动填写的服务器、跳板机（私有 ssh 配置用真的 `ssh -G` 解析验证，不联网）。
enum SelfTestConnection {
    static func run(_ check: (Bool, String) -> Void) {
        // 旧配置兼容
        let old = #"{"alias":"lab","auth":"interactive"}"#.data(using: .utf8)!
        let h0 = try? JSONDecoder().decode(HostConfig.self, from: old)
        check(h0?.auth == .interactive && h0?.isManual == false && h0?.rememberPassword == false && h0?.jumpHostID == nil,
              "连接：旧配置 auth=interactive 读成“动态口令”，新字段取默认值")

        var jump = HostConfig(alias: "bob@jump.example.org", displayName: "Jump", kind: .direct)
        jump.hostName = "jump.example.org"; jump.user = "bob"; jump.auth = .password
        var lab = HostConfig(alias: "alice@10.0.0.2", displayName: "Lab", kind: .slurm)
        lab.hostName = "10.0.0.2"; lab.user = "alice"; lab.port = 2222; lab.identityFile = "~/.ssh/id_lab"
        lab.auth = .keyPassword; lab.jumpHostID = jump.id
        var aliasHost = HostConfig(alias: "si-selftest-cluster", displayName: "Cluster")
        aliasHost.jumpHostID = lab.id

        if let data = try? JSONEncoder().encode(lab), let back = try? JSONDecoder().decode(HostConfig.self, from: data) {
            check(back == lab, "连接：新字段（地址 / 端口 / 用户 / 私钥 / 跳板机 / 认证）往返编码")
        } else {
            check(false, "连接：新字段往返编码")
        }

        // 跳板机链与防环
        let all = [jump, lab, aliasHost]
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        check(SSHHosts.chain(aliasHost, in: byID).map(\.displayName) == ["Lab", "Jump"], "连接：多级跳板机链 Cluster → Lab → Jump")
        var loopA = HostConfig(alias: "a"), loopB = HostConfig(alias: "b")
        loopA.jumpHostID = loopB.id; loopB.jumpHostID = loopA.id
        check(SSHHosts.chain(loopA, in: [loopA.id: loopA, loopB.id: loopB]).count == 1, "连接：跳板机成环时停下")
        check(!SSHHosts.jumpCandidates(for: jump, among: all).contains { $0.id == lab.id || $0.id == jump.id },
              "连接：跳板机候选里没有自己和以自己为跳板的机器")

        // 私有 ssh 配置
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("si-selftest-\(getpid())")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("ssh_config").path
        let text = SSHHosts.render(all, path: path, controlPath: { SSHHosts.needsPrivateConfig($0) ? "/tmp/serverisland-test/" + $0.id.uuidString.prefix(8).lowercased() + "-%C" : "/tmp/serverisland-test/%C" })
        check(text.contains("Host si-\(lab.id.uuidString)\n  HostName 10.0.0.2\n  User alice\n  Port 2222\n  IdentityFile ~/.ssh/id_lab\n  IdentitiesOnly yes"),
              "连接：手动服务器生成 Host 块")
        check(text.contains("Host si-selftest-cluster\n  ProxyCommand"), "连接：别名服务器经跳板机只加 ProxyCommand，其它设置仍来自 ~/.ssh/config")
        check(text.hasSuffix("Match all\nInclude ~/.ssh/config\nInclude /etc/ssh/ssh_config\n"), "连接：末尾包含用户和系统的 ssh 配置")
        check(text.contains("ControlPath='/tmp/serverisland-test/\(jump.id.uuidString.prefix(8).lowercased())-%%C'") && text.contains("-W '[%h]:%p'"),
              "连接：ProxyCommand 复用跳板机自己的主连接（%%C 留给内层 ssh）")
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        let g = sshG(["-F", path, "si-" + lab.id.uuidString])
        check(g.contains("hostname 10.0.0.2") && g.contains("port 2222") && g.contains("user alice")
              && g.contains("proxycommand env \(AskPass.envHostID)=\(jump.id.uuidString) /usr/bin/ssh"),
              "连接：ssh -G 能解析生成的配置（地址、端口、用户、跳板）")
        let g2 = sshG(["-F", path, "si-selftest-cluster"])
        check(g2.contains("si-\(lab.id.uuidString)") && g2.contains("\(AskPass.envHostID)=\(lab.id.uuidString)"),
              "连接：ssh -G 解析别名服务器的跳板机")

        // 提示语分类
        check(AskPass.kind(of: "(alice@10.0.0.2) Password: ") == .password, "弹窗：键盘交互的 Password 提示")
        check(AskPass.kind(of: "alice@10.0.0.2's password: ") == .password, "弹窗：OpenSSH 密码提示")
        check(AskPass.kind(of: "Verification code: ") == .oneTimeCode, "弹窗：动态口令提示")
        check(AskPass.kind(of: "Enter passphrase for key '/Users/x/.ssh/id_ed25519': ") == .passphrase, "弹窗：私钥口令提示")
        check(AskPass.kind(of: "Are you sure you want to continue connecting (yes/no/[fingerprint])? ") == .hostKey, "弹窗：主机指纹确认")
        check(AuthMode.keyPassword.canRemember && AuthMode.password.canRemember && !AuthMode.interactive.canRemember && !AuthMode.key.canRemember,
              "弹窗：只有密码类可以记住，动态口令不能")

        // 错误提示
        check(SSHRunner.keyFailureHint("alice@x: permission denied (password).").contains("密钥 + 密码"),
              "错误：密钥通过但还要密码 → 建议“密钥 + 密码”")
        check(SSHRunner.keyFailureHint("alice@x: permission denied (publickey,password).").contains("密码"),
              "错误：密钥被拒但服务器接受密码")
        check(SSHRunner.keyFailureHint("alice@x: permission denied (publickey).") == "密钥登录失败", "错误：只接受密钥")
        let badPerm = "Permissions 0755 for '/home/alice/.ssh/id_demo' are too open.\nLoad key \"/home/alice/.ssh/id_demo\": bad permissions\nalice@x: Permission denied (publickey,password)."
        check(SSHRunner.keyPermissionHint(badPerm)?.contains("chmod 600 /home/alice/.ssh/id_demo") == true
              && SSHRunner.keyPermissionHint("alice@x: Permission denied (publickey).") == nil
              && SSHRunner.classify(SSHResult(stdout: "", stderr: badPerm, status: 255, duration: 0, timedOut: false), host: HostConfig(alias: "x", kind: .direct)) == .needsLogin(SSHRunner.keyPermissionHint(badPerm)!),
              "错误：私钥权限太宽 → 提示 chmod 600")

        SSHHosts.update(all, write: false)
        let hopLogin = SSHRunner.jumpProblem("bob@jump.example.org: Permission denied (publickey,password).\nConnection closed by UNKNOWN port 65535", host: aliasHost)
        if case .needsLogin(let m)? = hopLogin { check(m.contains("第 2 级跳板机") && m.contains("Jump"), "错误：指明是哪一级跳板机要登录") }
        else { check(false, "错误：指明是哪一级跳板机要登录") }
        let hopRoute = SSHRunner.jumpProblem("channel 0: open failed: connect failed: No route to host\nstdio forwarding failed", host: lab)
        if case .error(let m)? = hopRoute { check(m.contains("Jump") && m.contains("连不上"), "错误：跳板机连不上目标") }
        else { check(false, "错误：跳板机连不上目标") }
        check(SSHRunner.jumpProblem("Permission denied", host: jump) == nil, "错误：没有跳板机时不误判")
        SSHHosts.update([], write: false)
    }

    private static func sshG(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-G"] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
