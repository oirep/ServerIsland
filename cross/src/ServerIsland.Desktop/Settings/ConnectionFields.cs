using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using ServerIsland.Core;
using ServerIsland.Core.Ssh;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Desktop.Settings;

/// 连接设置的几组控件（和 Mac 版 ConnectionFields.swift 对应）：服务器页和"添加服务器"共用。
/// edit：修改设置（服务器页会保存并在需要时重绘；添加对话框只改草稿）。
public static class ConnectionFields
{
    public const string AuthHelpZh = "密钥：后台直接用 SSH 密钥连接。\n密码：点“登录…”弹窗输入密码，连接在后台保持并复用。\n密钥 + 密码：服务器要求先过密钥、再输密码（两个都要）。\n动态口令：每次登录的验证码都不同（二次验证、令牌），只能每次手动输入。\n密码默认不保存；勾选“记住密码”时只存进系统凭据库。";
    public const string AuthHelpEn = "Key: connects in the background with your SSH key.\nPassword: click “Log In…” to enter it in a dialog; the connection is then kept alive and reused.\nKey + password: the server needs both — your key first, then a password.\nOne-time code: the code changes every time (2FA, tokens), so it is always typed by hand.\nPasswords are not stored unless you turn on “Remember Password”, and then only in the system credential store.";

    /// 地址、用户名、端口、私钥文件。
    public static IEnumerable<Control> Manual(SettingsKit k, HostConfig host, Action<Action<HostConfig>> edit, TopLevel? top)
    {
        yield return k.WideRow(L("地址", "Host"), L("服务器的 IP 或域名。也可以写成 user@地址。", "IP address or host name of the server. user@host also works."),
            k.Field(host.HostName, v => edit(h => h.HostName = v.Trim()), "10.0.0.2 / login.example.org", mono: true));
        yield return k.WideRow(L("用户名", "User"), null,
            k.Field(host.User, v => edit(h => h.User = v.Trim()), L("和本机用户名相同时可留空", "Leave empty to use your local user name"), mono: true));
        yield return k.WideRow(L("端口", "Port"), null,
            k.Field(host.Port?.ToString() ?? "", v => edit(h => h.Port = int.TryParse(new string(v.Where(char.IsDigit).ToArray()), out var p) && p > 0 ? p : null), "22", mono: true));
        var key = k.Field(host.IdentityFile, v => edit(h => h.IdentityFile = v.Trim()), L("默认（~/.ssh/id_*）", "Default (~/.ssh/id_*)"), mono: true);
        var pick = k.Button(L("选择…", "Choose…"), async () =>
        {
            if (top == null) return;
            var start = await top.StorageProvider.TryGetFolderFromPathAsync(AppPaths.SshDirectory);
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = L("选择私钥文件（不是 .pub 公钥）", "Choose a private key (not the .pub file)"),
                AllowMultiple = false,
                SuggestedStartLocation = start,
            });
            if (files.FirstOrDefault()?.TryGetLocalPath() is { } path) key.Text = AppPaths.Tilde(path);
        });
        var keyRow = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto") };
        keyRow.Children.Add(key);
        pick.Margin = new Avalonia.Thickness(6, 0, 0, 0);
        Grid.SetColumn(pick, 1);
        keyRow.Children.Add(pick);
        yield return k.WideRow(L("私钥文件", "Key File"),
            L("用哪个私钥登录。留空时使用 ~/.ssh 里的默认密钥。私钥有口令时会弹窗询问。",
              "Which private key to log in with. Leave empty to use the default keys in ~/.ssh. You will be asked for the passphrase if it has one."),
            keyRow);
    }

    /// 跳板机：从已添加的其它服务器里选（会成环的不列出）。
    public static Control Jump(SettingsKit k, HostConfig host, IEnumerable<HostConfig> all, Action<Action<HostConfig>> edit)
    {
        var items = new List<(Guid? Value, string Label)> { (null, L("不使用（直接连接）", "None (connect directly)")) };
        items.AddRange(SshHosts.JumpCandidates(host, all).Select(c => ((Guid?)c.Id, c.DisplayName + "  ·  " + SshHosts.Summary(c))));
        return k.Row(L("跳板机", "Jump Host"),
            L("先连到跳板机，再从跳板机连到这台服务器。跳板机要先作为一台服务器添加进来（不想监控它可以关掉“启用”）。跳板机已经登录时直接复用它的连接；需要密码时会按顺序分别询问每一跳。~/.ssh/config 里写好的 ProxyJump 照常有效，不用在这里重复设置。",
              "Connect to the jump host first, then from there to this server. Add the jump host as a server first (turn off “Enabled” if you don't want to monitor it). If the jump host is already logged in, its connection is reused; otherwise you are asked for each hop's password in turn. A ProxyJump in ~/.ssh/config keeps working — no need to set it here."),
            k.Combo(items, host.JumpHostID, v => edit(h => h.JumpHostID = v), minWidth: 240));
    }

    /// 认证方式 + "记住密码"。
    public static IEnumerable<Control> Auth(SettingsKit k, HostConfig host, Action<Action<HostConfig>> edit)
    {
        yield return k.Row(L("认证方式", "Authentication"), L(AuthHelpZh, AuthHelpEn),
            k.Combo(Enum.GetValues<AuthMode>().Select(a => (a, a.Label())), host.Auth, v => edit(h =>
            {
                h.Auth = v;
                if (!v.CanRemember() && h.RememberPassword)
                {
                    h.RememberPassword = false;
                    CredentialStore.Delete(h.Id);
                }
            })));
        if (!host.Auth.CanRemember()) yield break;
        if (!CredentialStore.Available)
        {
            yield return k.Caption(L("这台电脑没有可用的系统凭据库（需要 secret-tool / GNOME 钥匙圈），不能记住密码。",
                                     "No system credential store here (secret-tool / GNOME Keyring needed), so passwords can't be remembered."));
            yield break;
        }
        yield return k.ToggleRow(L("记住密码", "Remember Password"),
            OperatingSystem.IsWindows()
                ? L("默认不保存。打开后，下次登录时输入的密码存进 Windows 凭据管理器（不写进配置文件），连接断开后自动重新登录。关掉会立刻删除。",
                    "Off by default. When on, the password you enter at the next login is stored in Windows Credential Manager (never in the config file) and used to log in again automatically when the connection drops. Turning it off deletes it.")
                : L("默认不保存。打开后，下次登录时输入的密码存进系统钥匙圈（Secret Service，不写进配置文件），连接断开后自动重新登录。关掉会立刻删除。",
                    "Off by default. When on, the password you enter at the next login is stored in the system keyring (Secret Service, never in the config file) and used to log in again automatically when the connection drops. Turning it off deletes it."),
            host.RememberPassword, v => edit(h =>
            {
                h.RememberPassword = v;
                if (!v) CredentialStore.Delete(h.Id);
            }));
    }
}
