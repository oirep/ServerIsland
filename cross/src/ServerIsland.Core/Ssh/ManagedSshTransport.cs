using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Sockets;
using System.Text;
using Renci.SshNet;
using Renci.SshNet.Common;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core.Ssh;

/// 内置 SSH（SSH.NET）：Windows 自带的 OpenSSH 不支持 ControlMaster，所以由程序自己为每台服务器保持一条长连接，
/// 每次轮询只在这条连接上开一个新通道，和 Mac 版的连接复用效果一样。
/// - 读取 ~/.ssh/config 的 HostName / User / Port / IdentityFile / ProxyJump；也支持手动填写的地址；
/// - 跳板机（ServerIsland 里的另一台服务器）：一跳一跳转发，跳板机已登录时直接复用它的连接；
/// - 密码默认不保存；勾选"记住密码"时存进系统凭据库（CredentialStore），断线后自动重新登录；
/// - 用 ~/.ssh/known_hosts 校验主机指纹：没见过的指纹要用户确认，指纹变了直接拒绝；
/// - 密码 / 动态口令 / 密钥口令只在登录时经过对话框交给 SSH 库，不写到磁盘；
/// - 不支持 ssh-agent 和 ProxyCommand（这两种情况可以在设置里改用系统 ssh）。
/// 报错信息沿用 OpenSSH 的措辞（Permission denied、Could not resolve hostname…），这样 SshCommon.Classify 两边通用。
public sealed class ManagedSshTransport : ISshTransport
{
    public string Name => "managed";
    public bool SupportsPromptLogin => true;

    sealed class Conn : IDisposable
    {
        public SshClient Client = null!;
        public readonly List<SshClient> Hops = [];
        public readonly List<ForwardedPortLocal> Forwards = [];
        public DateTime? ExpiresAt;
        public string Target = "";

        public bool Alive => Client.IsConnected && (ExpiresAt == null || DateTime.Now < ExpiresAt);

        public void Dispose()
        {
            foreach (var f in Forwards) { try { f.Stop(); f.Dispose(); } catch { } }
            try { Client?.Disconnect(); Client?.Dispose(); } catch { }
            for (int i = Hops.Count - 1; i >= 0; i--) { try { Hops[i].Disconnect(); Hops[i].Dispose(); } catch { } }
        }
    }

    sealed class ConnectFailure(string sshText, string friendly) : Exception(sshText)
    {
        public string Friendly { get; } = friendly;
    }

    readonly ConcurrentDictionary<Guid, Conn> _conns = new();
    readonly ConcurrentDictionary<Guid, SemaphoreSlim> _locks = new();
    /// 本次运行内记住的密钥口令（只在内存里，退出即清除）。
    readonly ConcurrentDictionary<string, string> _passphrases = new();

    SemaphoreSlim LockFor(Guid id) => _locks.GetOrAdd(id, _ => new SemaphoreSlim(1, 1));

    public async Task<SshResult> RunAsync(HostConfig host, string remoteCommand, string? script, TimeSpan timeout)
    {
        var sw = Stopwatch.StartNew();
        Conn conn;
        try { conn = await GetConnectionAsync(host, null); }
        catch (ConnectFailure f) { return SshResult.Failure(f.Message, sw.Elapsed.TotalSeconds); }
        catch (Exception e) { return SshResult.Failure(e.Message, sw.Elapsed.TotalSeconds); }

        var stdin = SshCommon.FullScript(host, script);
        if (stdin != null) stdin = "LC_ALL=C; export LC_ALL\n" + stdin;
        try
        {
            return await ExecuteAsync(conn.Client, remoteCommand, stdin, timeout, sw);
        }
        catch (Exception e) when (e is SshConnectionException or ObjectDisposedException or SocketException or InvalidOperationException)
        {
            Drop(host.Id);
            DebugLog.Log($"[{host.DisplayName}] 内置 SSH 连接断开：{e.Message}");
            return SshResult.Failure(host.Auth.NeedsLogin()
                ? "Permission denied (keyboard-interactive): the connection was closed, please log in again"
                : "Connection closed by remote host", sw.Elapsed.TotalSeconds);
        }
    }

    static async Task<SshResult> ExecuteAsync(SshClient client, string command, string? stdin, TimeSpan timeout, Stopwatch sw)
    {
        using var cmd = client.CreateCommand(command);
        using var cts = new CancellationTokenSource(timeout);
        var exec = cmd.ExecuteAsync(cts.Token);
        using (var input = cmd.CreateInputStream())
        {
            if (stdin != null)
            {
                var bytes = new UTF8Encoding(false).GetBytes(stdin.Replace("\r\n", "\n"));
                await input.WriteAsync(bytes, cts.Token);
            }
        }
        try
        {
            await exec;
        }
        catch (OperationCanceledException)
        {
            return new SshResult(cmd.Result ?? "", cmd.Error ?? "", -1, sw.Elapsed.TotalSeconds, true);
        }
        return new SshResult(cmd.Result ?? "", cmd.Error ?? "", cmd.ExitStatus ?? (cmd.ExitSignal != null ? 128 : -1), sw.Elapsed.TotalSeconds, false);
    }

    /// 后台用记住的密码自动登录失败的时间（10 分钟内不再试，避免密码错了被服务器锁定）。
    readonly ConcurrentDictionary<Guid, DateTime> _autoFailedAt = new();
    readonly Dictionary<Guid, bool> _remember = [];

    public Dictionary<Guid, bool> TakeRememberChoices()
    {
        lock (_remember)
        {
            var copy = new Dictionary<Guid, bool>(_remember);
            _remember.Clear();
            return copy;
        }
    }

    /// 影响连接的设置（变了就要重连）。
    static string ConnKey(HostConfig h) =>
        string.Join("|", new[] { h.Alias, h.HostName, h.User, h.Port?.ToString() ?? "", h.IdentityFile }
            .Concat(SshHosts.JumpChain(h).Select(j => j.Id.ToString())));

    bool CanAutoLogin(HostConfig host) =>
        host.Auth.CanRemember() && host.RememberPassword
        && (!_autoFailedAt.TryGetValue(host.Id, out var t) || DateTime.Now - t > TimeSpan.FromMinutes(10))
        && CredentialStore.Has(host.Id);

    /// reuse：已有可用连接时直接用（跳板机）；否则 prompter 不为空表示用户点了"登录"，总是重新连接。
    async Task<Conn> GetConnectionAsync(HostConfig host, ILoginPrompter? prompter, bool reuse = false)
    {
        var gate = LockFor(host.Id);
        await gate.WaitAsync();
        try
        {
            if (_conns.TryGetValue(host.Id, out var c))
            {
                if (c.Alive && c.Target == ConnKey(host) && (prompter == null || reuse)) return c;
                Drop(host.Id);
            }
            bool auto = false;
            if (host.Auth.NeedsLogin() && prompter == null)
            {
                if (!CanAutoLogin(host))
                {
                    var (u, a) = UserAndAddress(host);
                    throw new ConnectFailure($"{u}@{a}: Permission denied (keyboard-interactive): not logged in", L("需要登录", "Login required"));
                }
                auto = true;
            }
            Conn conn;
            try { conn = await Task.Run(() => ConnectChain(host, prompter)); }
            catch when (auto) { _autoFailedAt[host.Id] = DateTime.Now; throw; }
            if (auto) DebugLog.Log($"[{host.DisplayName}] 已用记住的密码自动重新登录");
            if ((prompter != null || auto) && host.KeepAlive.Duration() is { } d) conn.ExpiresAt = DateTime.Now + d;
            _conns[host.Id] = conn;
            return conn;
        }
        finally { gate.Release(); }
    }

    /// 错误信息里用的 user@地址（和 OpenSSH 的措辞一样，方便 SshCommon 判断是哪一跳）。
    static (string User, string Address) UserAndAddress(HostConfig h)
    {
        var r = ResolveHost(h);
        return (r.User, r.HostName);
    }

    /// 手动填写的服务器：以 ~/.ssh/config 里的通配设置（Host *）为底，再用填写的值覆盖。
    static ResolvedHost ResolveHost(HostConfig h)
    {
        if (!h.IsManual) return SshConfig.Resolve(h.Alias);
        var r = SshConfig.Resolve(SshHosts.Target(h));
        var (user, addr) = SshHosts.SplitAddress(h);
        r.HostName = addr;
        if (user.Length > 0) r.User = user;
        if (h.Port is { } p && p > 0) r.Port = p;
        r.ProxyJump = null;
        r.ProxyCommand = null;
        if (h.IdentityFile.Trim() is { Length: > 0 } key) r.IdentityFiles = [SshConfig.ExpandTilde(key)];
        return r;
    }

    void Drop(Guid id)
    {
        if (_conns.TryRemove(id, out var c)) c.Dispose();
    }

    Conn ConnectChain(HostConfig host, ILoginPrompter? prompter)
    {
        var target = ResolveHost(host);
        var conn = new Conn { Target = ConnKey(host) };
        try
        {
            // ServerIsland 里设的跳板机：先拿到跳板机的连接（已登录就复用），再经它转发。
            var chain = SshHosts.JumpChain(host);
            if (chain.Count > 0)
            {
                var jump = chain[0];
                SshClient via;
                try { via = GetConnectionAsync(jump, prompter, reuse: true).GetAwaiter().GetResult().Client; }
                catch (ConnectFailure f)
                {
                    var (u, a) = UserAndAddress(jump);
                    var text = f.Message.Contains('@') ? f.Message : $"{u}@{a}: {f.Message}";
                    throw new ConnectFailure(text, L($"跳板机“{jump.DisplayName}”：{f.Friendly}", $"Jump host “{jump.DisplayName}”: {f.Friendly}"));
                }
                (string addr2, int port2) fwd;
                try { fwd = Forward(conn, via, target.HostName, target.Port); }
                catch (Exception e)
                {
                    throw new ConnectFailure("channel 0: open failed: " + e.Message + "\nstdio forwarding failed",
                        L($"跳板机“{jump.DisplayName}”连不上这台服务器", $"Jump host “{jump.DisplayName}” cannot reach this server"));
                }
                conn.Client = ConnectOne(host, target, fwd.addr2, fwd.port2, prompter, host.DisplayName);
                return conn;
            }

            if (target.ProxyCommand != null)
                throw new ConnectFailure("ProxyCommand is not supported by the built-in SSH",
                    L("内置 SSH 不支持 ProxyCommand，请在设置里改用系统 ssh，或改用 ProxyJump", "The built-in SSH doesn't support ProxyCommand; use ProxyJump or switch to system ssh"));
            string addr = target.HostName;
            int port = target.Port;
            if (target.ProxyJump is { } pj)
            {
                SshClient? prev = null;
                foreach (var hop in pj.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
                {
                    var hr = SshConfig.Resolve(hop);
                    var (ha, hp) = prev == null ? (hr.HostName, hr.Port) : Forward(conn, prev, hr.HostName, hr.Port);
                    var client = ConnectOne(null, hr, ha, hp, prompter, host.DisplayName + " → " + hop);
                    conn.Hops.Add(client);
                    prev = client;
                }
                (addr, port) = Forward(conn, prev!, target.HostName, target.Port);
            }
            conn.Client = ConnectOne(host, target, addr, port, prompter, host.DisplayName);
            return conn;
        }
        catch
        {
            conn.Dispose();
            throw;
        }
    }

    static (string, int) Forward(Conn conn, SshClient via, string host, int port)
    {
        var fwd = new ForwardedPortLocal("127.0.0.1", 0, host, (uint)port);
        via.AddForwardedPort(fwd);
        fwd.Start();
        conn.Forwards.Add(fwd);
        return ("127.0.0.1", (int)fwd.BoundPort);
    }

    /// cfg 为空表示 ~/.ssh/config 里 ProxyJump 的中间一跳（没有 ServerIsland 设置，按密钥 + 弹窗处理）。
    SshClient ConnectOne(HostConfig? cfg, ResolvedHost r, string address, int port, ILoginPrompter? prompter, string displayName)
    {
        var keys = LoadKeys(r, prompter, displayName);
        bool cancelled = false;
        var auth = cfg?.Auth ?? AuthMode.Key;

        // 密码 / 密钥 + 密码：先用记住的密码，没有就弹窗问（可勾选记住）。
        string? password = null;
        bool fromStore = false;
        bool? rememberChoice = null;
        if (cfg != null && auth.CanRemember())
        {
            if (cfg.RememberPassword && CredentialStore.Get(cfg.Id) is { } saved)
            {
                password = saved;
                fromStore = true;
            }
            else if (prompter != null)
            {
                var (pw, rem) = prompter.AskPasswordAsync(displayName, L($"{r.User}@{r.HostName} 的密码", $"Password for {r.User}@{r.HostName}"),
                                                          cfg.RememberPassword && CredentialStore.Available).GetAwaiter().GetResult();
                if (pw == null) throw new ConnectFailure("Permission denied: cancelled", L("登录已取消", "Login cancelled"));
                password = pw;
                rememberChoice = rem;
            }
        }

        List<AuthenticationMethod> Methods(string? pw)
        {
            var methods = new List<AuthenticationMethod>();
            if (keys.Count > 0) methods.Add(new PrivateKeyAuthenticationMethod(r.User, [.. keys]));
            if (pw != null) methods.Add(new PasswordAuthenticationMethod(r.User, pw));
            if (prompter != null || pw != null)
            {
                bool usedPassword = false;
                var kbd = new KeyboardInteractiveAuthenticationMethod(r.User);
                kbd.AuthenticationPrompt += (_, e) =>
                {
                    foreach (var p in e.Prompts)
                    {
                        if (cancelled) { p.Response = ""; continue; }
                        var text = string.Join("\n", new[] { e.Instruction, p.Request }.Where(s => !string.IsNullOrWhiteSpace(s))).Trim();
                        // 服务器用键盘交互方式要密码时，用已有的密码答一次；动态口令等其它提示照常弹窗。
                        if (pw != null && !usedPassword && SshHosts.Kind(text) == SshHosts.PromptKind.Password)
                        {
                            usedPassword = true;
                            p.Response = pw;
                            continue;
                        }
                        if (prompter == null) { p.Response = ""; continue; }
                        var answer = prompter.AskAsync(displayName, text, !p.IsEchoed).GetAwaiter().GetResult();
                        if (answer == null) cancelled = true;
                        p.Response = answer ?? "";
                    }
                };
                methods.Add(kbd);
            }
            return methods;
        }

        var first = Methods(password);
        if (first.Count == 0)
            throw new ConnectFailure("Permission denied (publickey): no usable key in ~/.ssh",
                L("~/.ssh 里没有可用的密钥（或密钥有口令），请点“登录…”", "No usable key in ~/.ssh (or it has a passphrase); click Log In"));

        try
        {
            var client = TryConnect(r, address, port, prompter, displayName, first);
            if (cfg != null && rememberChoice is { } rem) ApplyRemember(cfg, rem, password!);
            return client;
        }
        catch (ConnectFailure f) when (prompter != null && !cancelled && f.Message.StartsWith("Permission denied", StringComparison.Ordinal)
                                       && (fromStore || (password == null && f.Message.Contains("password", StringComparison.OrdinalIgnoreCase)
                                                         && !f.Message.Contains("keyboard-interactive", StringComparison.OrdinalIgnoreCase))))
        {
            // 记住的密码不对了，或者服务器只接受 password 方式（不接受键盘交互）：再问一次密码。密钥照样带上（密钥 + 密码的服务器两样都要）。
            var canRemember = cfg != null && auth.CanRemember() && CredentialStore.Available;
            var (pw, rem) = prompter.AskPasswordAsync(displayName,
                (fromStore ? L("记住的密码没有通过，请重新输入。\n", "The saved password was rejected. Please enter it again.\n") : "")
                + L($"{r.User}@{r.HostName} 的密码", $"Password for {r.User}@{r.HostName}"), canRemember && cfg!.RememberPassword).GetAwaiter().GetResult();
            if (pw == null) throw new ConnectFailure("Permission denied: cancelled", L("登录已取消", "Login cancelled"));
            var client = TryConnect(r, address, port, prompter, displayName, Methods(pw));
            if (canRemember) ApplyRemember(cfg!, rem, pw);
            return client;
        }
        finally
        {
            if (cancelled) DebugLog.Log($"[{displayName}] 用户取消了登录");
        }
    }

    /// 登录成功后按用户的选择保存 / 删除记住的密码。
    void ApplyRemember(HostConfig cfg, bool remember, string password)
    {
        if (remember) CredentialStore.Save(cfg.Id, password, cfg.DisplayName);
        else CredentialStore.Delete(cfg.Id);
        lock (_remember) _remember[cfg.Id] = remember;
    }

    SshClient TryConnect(ResolvedHost r, string address, int port, ILoginPrompter? prompter, string displayName, List<AuthenticationMethod> methods)
    {
        var info = new ConnectionInfo(address, port, r.User, [.. methods])
        {
            Timeout = TimeSpan.FromSeconds(r.ConnectTimeout ?? (prompter != null ? 30 : 10)),
        };
        var keyHost = r.HostKeyAlias ?? r.HostName;
        PreferKnownHostKeyTypes(info, keyHost, r.Port, r.UserKnownHostsFile);
        var client = new SshClient(info) { KeepAliveInterval = TimeSpan.FromSeconds(prompter != null ? 30 : 15) };
        ConnectFailure? hostKeyProblem = null;
        client.HostKeyReceived += (_, e) =>
        {
            var verdict = KnownHosts.Check(keyHost, r.Port, e.HostKeyName, e.HostKey, r.UserKnownHostsFile);
            switch (verdict)
            {
                case KnownHosts.Verdict.Match:
                    e.CanTrust = true;
                    return;
                case KnownHosts.Verdict.Mismatch when r.StrictHostKeyChecking != "no":
                    hostKeyProblem = new ConnectFailure("WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED",
                        L($"{keyHost} 的主机指纹和 known_hosts 里记录的不一样，可能有风险，已拒绝连接。确认无误后请手动编辑 ~/.ssh/known_hosts。",
                          $"The host key of {keyHost} doesn't match ~/.ssh/known_hosts; the connection was refused. If this is expected, edit known_hosts yourself."));
                    e.CanTrust = false;
                    return;
            }
            var fp = KnownHosts.Fingerprint(e.HostKey);
            bool accept = r.StrictHostKeyChecking is "no" or "accept-new" or "off";
            if (!accept && prompter != null)
            {
                accept = prompter.ConfirmHostKeyAsync(displayName,
                    L($"第一次连接 {keyHost}（端口 {r.Port}）。\n{e.HostKeyName} 指纹：\n{fp}\n\n确认这是你的服务器后再继续，指纹会记到 ~/.ssh/known_hosts。",
                      $"First connection to {keyHost} (port {r.Port}).\n{e.HostKeyName} fingerprint:\n{fp}\n\nContinue only if this is your server. The key will be added to ~/.ssh/known_hosts."))
                    .GetAwaiter().GetResult();
            }
            if (accept)
            {
                try { KnownHosts.Add(keyHost, r.Port, NormalizeKeyType(e.HostKeyName), e.HostKey, r.UserKnownHostsFile); } catch { }
                e.CanTrust = true;
            }
            else
            {
                hostKeyProblem = new ConnectFailure("Host key verification failed.",
                    L("首次连接需要确认主机指纹，请点“登录…”", "Confirm the host key first: click Log In"));
                e.CanTrust = false;
            }
        };

        try
        {
            client.Connect();
            return client;
        }
        catch (Exception e)
        {
            client.Dispose();
            if (hostKeyProblem != null) throw hostKeyProblem;
            throw Translate(e, r);
        }
    }

    static ConnectFailure Translate(Exception e, ResolvedHost r)
    {
        switch (e)
        {
            case ConnectFailure f: return f;
            case SshAuthenticationException a:
                // 按 OpenSSH 的格式写成 "user@host: Permission denied (方法)."：SshCommon 据此判断"密钥已通过、还差密码"和是哪一跳失败。
                var listed = System.Text.RegularExpressions.Regex.Match(a.Message, @"\(([^)]*)\)");
                return new ConnectFailure($"{r.User}@{r.HostName}: Permission denied ({(listed.Success ? listed.Groups[1].Value : "publickey")}). {a.Message}",
                    L("认证失败（密码 / 口令不对，或服务器不接受这个密钥）", "Authentication failed (wrong password / code, or the key isn't accepted)"));
            case SocketException s:
                return s.SocketErrorCode switch
                {
                    SocketError.HostNotFound or SocketError.NoData or SocketError.TryAgain =>
                        new ConnectFailure($"ssh: Could not resolve hostname {r.HostName}", L("无法解析主机名", "Cannot resolve host name")),
                    SocketError.ConnectionRefused => new ConnectFailure("Connection refused", L("连接被拒绝", "Connection refused")),
                    SocketError.TimedOut => new ConnectFailure("Connection timed out", L("连接超时", "Connection timed out")),
                    SocketError.NetworkUnreachable or SocketError.HostUnreachable =>
                        new ConnectFailure("Network is unreachable", L("网络不可达", "Network unreachable")),
                    _ => new ConnectFailure(s.Message, s.Message),
                };
            case SshOperationTimeoutException:
                return new ConnectFailure("Connection timed out", L("连接超时", "Connection timed out"));
            case SshConnectionException c:
                return new ConnectFailure("Connection closed: " + c.Message, c.Message);
            default:
                return new ConnectFailure(e.Message, e.Message);
        }
    }

    /// known_hosts 里已经记了某种类型的指纹时，优先协商这种类型（和 OpenSSH 的行为一致），避免误报"没见过的指纹"。
    static void PreferKnownHostKeyTypes(ConnectionInfo info, string host, int port, string? knownHostsFile)
    {
        var file = knownHostsFile ?? KnownHosts.DefaultPath;
        if (!File.Exists(file)) return;
        var types = new List<string>();
        foreach (var family in new[] { "ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521", "ssh-rsa" })
        {
            // 用一把假的 key 只看主机名 + 类型有没有记录：Mismatch 表示有这种类型的条目
            if (KnownHosts.Check(host, port, family, [0], file) == KnownHosts.Verdict.Mismatch) types.Add(family);
        }
        if (types.Count == 0) return;
        var algs = info.HostKeyAlgorithms;
        var ordered = algs.OrderBy(kv => types.Contains(NormalizeKeyType(kv.Key)) ? 0 : 1).ToList();
        algs.Clear();
        foreach (var kv in ordered) algs.Add(kv.Key, kv.Value);
    }

    /// rsa-sha2-256 / rsa-sha2-512 在 known_hosts 里记作 ssh-rsa。
    static string NormalizeKeyType(string algorithm) =>
        algorithm.StartsWith("rsa-sha2", StringComparison.Ordinal) ? "ssh-rsa" : algorithm;

    List<IPrivateKeySource> LoadKeys(ResolvedHost r, ILoginPrompter? prompter, string displayName)
    {
        var paths = r.IdentityFiles.Count > 0
            ? r.IdentityFiles
            : new[] { "id_ed25519", "id_ecdsa", "id_rsa" }.Select(n => Path.Combine(AppPaths.SshDirectory, n)).ToList();
        var keys = new List<IPrivateKeySource>();
        foreach (var path in paths.Where(File.Exists))
        {
            try { keys.Add(new PrivateKeyFile(path)); continue; }
            catch (SshPassPhraseNullOrEmptyException) { }
            catch (Exception e) { DebugLog.Log($"[{displayName}] 读不了密钥 {path}：{e.Message}"); continue; }

            // 有口令的密钥：用本次运行里记住的口令，或者登录时问一次。
            if (_passphrases.TryGetValue(path, out var saved))
            {
                try { keys.Add(new PrivateKeyFile(path, saved)); continue; } catch { _passphrases.TryRemove(path, out _); }
            }
            if (prompter == null) continue;
            var pass = prompter.AskAsync(displayName, L($"密钥 {AppPaths.Tilde(path)} 的口令", $"Passphrase for {AppPaths.Tilde(path)}"), true).GetAwaiter().GetResult();
            if (string.IsNullOrEmpty(pass)) continue;
            try
            {
                keys.Add(new PrivateKeyFile(path, pass));
                _passphrases[path] = pass;
            }
            catch (Exception e) { DebugLog.Log($"[{displayName}] 密钥口令不对：{e.Message}"); }
        }
        return keys;
    }

    public async Task<string?> LoginAsync(HostConfig host, ILoginPrompter prompter)
    {
        try
        {
            await GetConnectionAsync(host, prompter);
            return null;
        }
        catch (ConnectFailure f) { return f.Friendly; }
        catch (Exception e) { return e.Message; }
    }

    public async Task<string?> AutoLoginAsync(HostConfig host)
    {
        // 内置 SSH 在轮询时就会用记住的密码自动连接，这里只是立刻试一次。
        try { await GetConnectionAsync(host, null, reuse: true); return null; }
        catch (ConnectFailure f) { return f.Friendly; }
        catch (Exception e) { return e.Message; }
    }

    public Task<bool> IsLoggedInAsync(HostConfig host) =>
        Task.FromResult(_conns.TryGetValue(host.Id, out var c) && c.Alive);

    public Task CloseAsync(HostConfig host)
    {
        Drop(host.Id);
        return Task.CompletedTask;
    }
}
