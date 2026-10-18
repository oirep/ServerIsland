import AppKit
import SwiftUI

/// 手动填写的连接信息：地址、端口、用户名、私钥文件。服务器页和"添加服务器"共用。
struct ManualAddressFields: View {
    @Binding var host: HostConfig

    var body: some View {
        LabeledContent {
            field($host.hostName, "10.0.0.2 / login.example.org")
        } label: {
            HelpLabel(L("地址", "Host"), help: L("服务器的 IP 或域名。也可以写成 user@地址。", "IP address or host name of the server. user@host also works."))
        }
        LabeledContent(L("用户名", "User")) {
            field($host.user, L("和本机用户名相同时可留空", "Leave empty to use your local user name"))
        }
        LabeledContent(L("端口", "Port")) {
            field(Binding(get: { host.port.map(String.init) ?? "" }, set: { host.port = Int($0.filter(\.isNumber)) }), "22")
        }
        LabeledContent {
            HStack(spacing: 6) {
                TextField("", text: $host.identityFile, prompt: Text(L("默认（ssh-agent / ~/.ssh/id_*）", "Default (ssh-agent / ~/.ssh/id_*)")))
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                Button(L("选择…", "Choose…")) { pickKey() }
            }
        } label: {
            HelpLabel(L("私钥文件", "Key File"),
                      help: L("用哪个私钥登录。留空时使用 ssh 的默认密钥和 ssh-agent。私钥有口令时会弹窗询问（建议先 ssh-add --apple-use-keychain）。",
                              "Which private key to log in with. Leave empty to use ssh's default keys and ssh-agent. If the key has a passphrase you will be asked for it (tip: ssh-add --apple-use-keychain)."))
        }
    }

    private func field(_ text: Binding<String>, _ prompt: String) -> some View {
        TextField("", text: text, prompt: Text(prompt))
            .labelsHidden()
            .multilineTextAlignment(.trailing)
            .font(.system(.body, design: .monospaced))
    }

    private func pickKey() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory() + "/.ssh")
        panel.message = L("选择私钥文件（不是 .pub 公钥）", "Choose a private key (not the .pub file)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        host.identityFile = (url.path as NSString).abbreviatingWithTildeInPath
    }
}

/// 跳板机选择：从已添加的其它服务器里选（会成环的不列出）。
struct JumpHostPicker: View {
    @Binding var host: HostConfig
    var allHosts: [HostConfig]

    var body: some View {
        let candidates = SSHHosts.jumpCandidates(for: host, among: allHosts)
        Picker(selection: $host.jumpHostID) {
            Text(L("不使用（直接连接）", "None (connect directly)")).tag(UUID?.none)
            ForEach(candidates) { c in
                Text(c.displayName + "  ·  " + SSHHosts.summary(c)).tag(UUID?.some(c.id))
            }
        } label: {
            HelpLabel(L("跳板机", "Jump Host"),
                      help: L("先连到跳板机，再从跳板机连到这台服务器。跳板机要先作为一台服务器添加进来（不想监控它可以关掉“启用”）。跳板机已经登录时直接复用它的连接；需要密码时会按顺序分别询问每一跳。~/.ssh/config 里写好的 ProxyJump 照常有效，不用在这里重复设置。",
                              "Connect to the jump host first, then from there to this server. Add the jump host as a server first (turn off “Enabled” if you don't want to monitor it). If the jump host is already logged in, its connection is reused; otherwise you are asked for each hop's password in turn. A ProxyJump in ~/.ssh/config keeps working — no need to set it here."))
        }
    }
}

/// 认证方式 + "记住密码"。
struct AuthFields: View {
    @Binding var host: HostConfig

    var body: some View {
        Picker(selection: $host.auth) {
            ForEach(AuthMode.allCases) { Text($0.label).tag($0) }
        } label: {
            HelpLabel(L("认证方式", "Authentication"), help: Self.help)
        }
        .onChange(of: host.auth) { _, mode in
            if !mode.canRemember && host.rememberPassword {
                host.rememberPassword = false
                Keychain.delete(host.id)
            }
        }
        if host.auth.canRemember {
            Toggle(isOn: $host.rememberPassword) {
                HelpLabel(L("记住密码", "Remember Password"),
                          help: L("默认不保存。打开后，下次登录时输入的密码存进 macOS 钥匙串（不写进配置文件），连接断开后自动重新登录。关掉会立刻从钥匙串删除。",
                                  "Off by default. When on, the password you enter at the next login is stored in the macOS Keychain (never in the config file) and used to log in again automatically when the connection drops. Turning it off deletes it from the Keychain."))
            }
            .onChange(of: host.rememberPassword) { _, on in if !on { Keychain.delete(host.id) } }
        }
    }

    static let help = L("""
        密钥：后台直接用 ssh 密钥 / ssh-agent 连接。
        密码：点“登录…”弹窗输入密码，连接在后台保持并复用。
        密钥 + 密码：服务器要求先过密钥、再输密码（两个都要）。
        动态口令：每次登录的验证码都不同（二次验证、令牌），只能每次手动输入。
        密码默认不保存；勾选“记住密码”时只存进系统钥匙串。
        """, """
        Key: connects in the background with your SSH key / ssh-agent.
        Password: click “Log In…” to enter it in a dialog; the connection is then kept alive and reused.
        Key + password: the server needs both — your key first, then a password.
        One-time code: the code changes every time (2FA, tokens), so it is always typed by hand.
        Passwords are not stored unless you turn on “Remember Password”, and then only in the system keychain.
        """)
}
