using static ServerIsland.Core.Lang;

namespace ServerIsland.Core.Ssh;

public sealed record SshResult(string Stdout, string Stderr, int Status, double Duration, bool TimedOut)
{
    public static SshResult Failure(string stderr, double duration = 0) => new("", stderr, 255, duration, false);
}

/// 登录时向用户要密码 / 动态口令 / 确认主机指纹（由界面实现）。返回 null 表示用户取消。
public interface ILoginPrompter
{
    Task<string?> AskAsync(string hostName, string prompt, bool secret);
    Task<bool> ConfirmHostKeyAsync(string hostName, string message);
    /// 要密码，并让用户选择是否记住（存进系统凭据库）。返回 Value=null 表示取消。
    Task<(string? Value, bool Remember)> AskPasswordAsync(string hostName, string prompt, bool rememberDefault) =>
        AskAsync(hostName, prompt, true).ContinueWith(t => (t.Result, false));
}

/// 两种实现：系统 ssh（ControlMaster 复用连接）和内置 SSH.NET（应用内保持长连接）。
public interface ISshTransport
{
    string Name { get; }
    /// 是否支持在应用里弹窗登录（密码 / 动态口令）。
    bool SupportsPromptLogin { get; }
    Task<SshResult> RunAsync(HostConfig host, string remoteCommand, string? script, TimeSpan timeout);
    /// 弹窗登录，成功后连接保持（时长见 host.KeepAlive）。返回 null 表示成功，否则是错误说明。
    Task<string?> LoginAsync(HostConfig host, ILoginPrompter prompter);
    Task<bool> IsLoggedInAsync(HostConfig host);
    Task CloseAsync(HostConfig host);
    /// 后台用记住的密码重新登录（不弹窗）。返回 null 表示成功。
    Task<string?> AutoLoginAsync(HostConfig host);
    /// 登录过程中用户在弹窗里勾选 / 取消"记住密码"的机器（含跳板机），取出后清空。
    Dictionary<Guid, bool> TakeRememberChoices();
}

public static class SshCommon
{
    /// 非交互 shell 不会执行 ~/.bashrc 里 `case $- in *i*)` 之后的内容（Ubuntu 默认如此），
    /// 所以装在家目录下的 Slurm / GPUMD 等常常"找不到命令"。这里把 rc 文件里 PATH= 行中
    /// 实际存在的目录追加到 PATH 末尾（只追加、不覆盖，含其它变量的条目跳过），不启动交互式 shell。
    public const string PathPrelude = """
        for SI_D in $(grep -hE '^[[:space:]]*(export[[:space:]]+)?PATH=' ~/.bashrc ~/.bash_profile ~/.profile ~/.zshrc 2>/dev/null \
            | sed -E 's/^[[:space:]]*(export[[:space:]]+)?PATH=//; s/[;#].*$//; s/["'"'"']//g' | tr ':' '\n' \
            | sed -e "s#^~#$HOME#" -e "s#\$HOME#$HOME#g" -e "s#\${HOME}#$HOME#g" | grep -v '\$') /opt/slurm/bin /usr/local/slurm/bin; do
          case ":$PATH:" in *":$SI_D:"*) ;; *) [ -d "$SI_D" ] && PATH="$PATH:$SI_D" ;; esac
        done; export PATH; unset SI_D

        """;

    public static string? FullScript(HostConfig host, string? script) =>
        script == null ? null : (host.ImportShellPath ? PathPrelude : "") + script;

    /// 把 ssh 自身的错误（退出码 255）翻译成用户能看懂的状态。内置 SSH 也按 OpenSSH 的措辞报错，共用这里的判断。
    public static HostHealth? Classify(SshResult result, HostConfig host)
    {
        if (result.TimedOut) return HostHealth.Error(L("连接超时", "Connection timed out"));
        if (result.Status != 255) return null;
        var err = result.Stderr.Trim();
        var lower = err.ToLowerInvariant();
        if (lower.Contains("host key verification failed"))
            return HostHealth.NeedsLogin(L("首次连接需要确认主机指纹", "Confirm the host key on first connection"));
        if (lower.Contains("remote host identification has changed"))
            return HostHealth.Error(L("服务器的主机指纹变了，可能有风险", "The server's host key has changed"));
        if (JumpProblem(err, host) is { } hop) return hop;
        if (lower.Contains("permission denied") || lower.Contains("too many authentication")
            || lower.Contains("keyboard-interactive") || (lower.Contains("control socket") && host.Auth.NeedsLogin()))
            return HostHealth.NeedsLogin(host.Auth.NeedsLogin() ? L("需要登录", "Login required") : KeyFailureHint(lower));
        if (host.Auth.NeedsLogin() && (lower.Contains("no such file") || lower.Length == 0))
            return HostHealth.NeedsLogin(L("需要登录", "Login required"));
        if (lower.Contains("could not resolve")) return HostHealth.Error(L("无法解析主机名", "Cannot resolve host name"));
        if (lower.Contains("connection refused")) return HostHealth.Error(L("连接被拒绝", "Connection refused"));
        if (lower.Contains("timed out")) return HostHealth.Error(L("连接超时", "Connection timed out"));
        if (lower.Contains("no route") || lower.Contains("network is unreachable")) return HostHealth.Error(L("网络不可达", "Network unreachable"));
        var lines = err.Split('\n').Select(l => l.Trim()).Where(l => l.Length > 0).ToList();
        return HostHealth.Error(lines.Count > 0 ? lines[^1] : L("ssh 连接失败", "ssh connection failed"));
    }

    /// 密钥登录被拒时，根据服务器列出的认证方式给出建议。
    /// `Permission denied (password).` 这类不含 publickey 的列表说明密钥已经通过（partial success），还差密码。
    public static string KeyFailureHint(string lower)
    {
        var m = System.Text.RegularExpressions.Regex.Match(lower, @"permission denied \(([^)]*)\)");
        if (!m.Success) return L("密钥登录失败", "Key login failed");
        var methods = m.Groups[1].Value.Split([',', ' '], StringSplitOptions.RemoveEmptyEntries);
        bool wantsPassword = methods.Contains("password") || methods.Contains("keyboard-interactive");
        if (wantsPassword && !methods.Contains("publickey"))
            return L("密钥已通过，服务器还要求密码：认证方式请选“密钥 + 密码”", "Key accepted, but the server also wants a password: choose “Key + password”");
        if (wantsPassword)
            return L("密钥登录失败（服务器也接受密码，可改用“密码”登录）", "Key login failed (the server also accepts a password: try “Password”)");
        return L("密钥登录失败", "Key login failed");
    }

    /// 经跳板机时，判断是不是某一跳出了问题，并指明是哪一跳。
    public static HostHealth? JumpProblem(string err, HostConfig host)
    {
        var chain = SshHosts.JumpChain(host);
        if (chain.Count == 0) return null;
        var lower = err.ToLowerInvariant();
        // 跳板机本身登录成功，但它连不上目标
        if (lower.Contains("stdio forwarding failed") || lower.Contains("open failed") || lower.Contains("administratively prohibited"))
            return HostHealth.Error(L($"跳板机“{chain[0].DisplayName}”连不上这台服务器", $"Jump host “{chain[0].DisplayName}” cannot reach this server"));
        // 错误信息里带着某一跳的地址
        var lines = err.Split('\n').Select(l => l.ToLowerInvariant()).ToList();
        for (int i = chain.Count - 1; i >= 0; i--)
        {
            var hop = chain[i];
            var names = HopNames(hop);
            if (!lines.Any(l => names.Any(n => l.Contains("@" + n + ":") || l.Contains("to " + n + " ") || l.Contains("host " + n + " ") || l.Contains("resolve hostname " + n))))
                continue;
            var what = i == 0 ? L("跳板机", "Jump host") : L($"第 {i + 1} 级跳板机", $"Jump host #{i + 1}");
            if (lower.Contains("permission denied") || lower.Contains("too many authentication"))
                return HostHealth.NeedsLogin(hop.Auth.NeedsLogin()
                    ? L($"{what}“{hop.DisplayName}”需要登录", $"{what} “{hop.DisplayName}” needs login")
                    : L($"{what}“{hop.DisplayName}”：{KeyFailureHint(lower)}", $"{what} “{hop.DisplayName}”: {KeyFailureHint(lower)}"));
            if (lower.Contains("host key verification failed"))
                return HostHealth.NeedsLogin(L($"{what}“{hop.DisplayName}”需要确认主机指纹", $"Confirm the host key of {what.ToLowerInvariant()} “{hop.DisplayName}”"));
            return HostHealth.Error(L($"{what}“{hop.DisplayName}”连接失败", $"{what} “{hop.DisplayName}” unreachable"));
        }
        if (lower.Contains("kex_exchange_identification") || lower.Contains("connection closed by unknown")
            || (lower.Contains("closed by remote host") && !lower.Contains('@')))
            return HostHealth.Error(L($"经跳板机“{chain[0].DisplayName}”连接失败", $"Connection via jump host “{chain[0].DisplayName}” failed"));
        return null;
    }

    /// 错误信息里可能出现的地址：别名、HostName。
    static List<string> HopNames(HostConfig hop)
    {
        var names = new List<string>();
        if (hop.IsManual) names.Add(SshHosts.SplitAddress(hop).Host.ToLowerInvariant());
        else
        {
            var a = hop.Alias.ToLowerInvariant();
            if (a.LastIndexOf('@') is var at and >= 0) a = a[(at + 1)..];
            names.Add(a);
            var hn = SshConfig.Resolve(hop.Alias).HostName;
            if (!string.IsNullOrEmpty(hn)) names.Add(hn.ToLowerInvariant());
        }
        return names.Where(n => n.Length > 0).Distinct().ToList();
    }

    public static ISshTransport Create(SshBackend backend) => Resolve(backend) == SshBackend.Managed
        ? new ManagedSshTransport()
        : new OpenSshTransport();

    /// 自动：Windows 上的 OpenSSH 不支持 ControlMaster，用内置 SSH；其它平台用系统 ssh（和 Mac 版一样）。
    public static SshBackend Resolve(SshBackend backend) => backend switch
    {
        SshBackend.Auto => OperatingSystem.IsWindows() ? SshBackend.Managed : SshBackend.OpenSsh,
        _ => backend,
    };
}
