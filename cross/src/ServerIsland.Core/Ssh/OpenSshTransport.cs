using System.Diagnostics;
using System.Text;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core.Ssh;

/// 调用系统 ssh。这样 `~/.ssh/config` 中的 ProxyJump、IdentityFile、ssh-agent 等设置全部自动生效。
/// Linux / macOS 默认启用 ControlMaster 连接复用：只有第一次需要握手，之后的轮询只是在已有连接上开一个新通道。
/// Windows 自带的 OpenSSH 不支持 ControlMaster，选了这个实现时每次轮询都会重新握手（只建议密钥登录的机器用）。
public sealed class OpenSshTransport : ISshTransport
{
    public string Name => "openssh";
    public bool SupportsPromptLogin => SupportsControlMaster;

    public static bool SupportsControlMaster => !OperatingSystem.IsWindows();

    public static string SshPath
    {
        get
        {
            if (OperatingSystem.IsWindows())
            {
                var sys = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "OpenSSH", "ssh.exe");
                return File.Exists(sys) ? sys : "ssh.exe";
            }
            return File.Exists("/usr/bin/ssh") ? "/usr/bin/ssh" : "ssh";
        }
    }

    /// Unix socket 路径有 104 字节上限，所以放在短路径下。
    public static string ControlDirectory => "/tmp/serverisland-" + Environment.UserName;
    public static string ControlPath => ControlDirectory + "/%C";

    /// 每台机器的主连接 socket。手动填写 / 经跳板机的机器在 %C 前加上自己 ID 的前 8 位：
    /// 不同跳板机后面的两台服务器可能是同一个内网地址（%C 只按地址、端口、用户算，会撞在一起）。
    public static string ControlPathFor(HostConfig host) =>
        SshHosts.NeedsPrivateConfig(host) ? ControlDirectory + "/" + host.Id.ToString("N")[..8] + "-%C" : ControlPath;

    /// 手动填写 / 经跳板机的服务器要用 App 的私有 ssh 配置（见 SshHosts）。
    public static List<string> ConfigArgs(HostConfig host)
    {
        if (!SupportsControlMaster || !SshHosts.NeedsPrivateConfig(host)) return [];
        SshHosts.EnsureWritten();
        return ["-F", SshHosts.ConfigPath];
    }

    /// ssh 命令行上的目标（别名或 si-UUID）。Windows 上的系统 ssh 不用私有配置，只能按别名连接。
    public static string TargetFor(HostConfig host) => SupportsControlMaster ? SshHosts.Target(host) : host.Alias;

    public static void EnsureControlDirectory()
    {
        if (!SupportsControlMaster || Directory.Exists(ControlDirectory)) return;
        try
        {
            Directory.CreateDirectory(ControlDirectory);
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(ControlDirectory, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        catch { }
    }

    public static List<string> Options(HostConfig host, int connectTimeout = 10)
    {
        var opts = ConfigArgs(host);
        opts.AddRange(new[]
        {
            "-o", "BatchMode=yes",              // 绝不在后台卡住等待密码输入
            "-o", $"ConnectTimeout={connectTimeout}",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=2",
            "-o", "LogLevel=ERROR",
            "-T",
        });
        if (SupportsControlMaster && (host.ReuseConnection || host.Auth.NeedsLogin()))
        {
            EnsureControlDirectory();
            // 免密主机：自动建立并保持主连接；需要密码的主机：只复用用户登录时建立的主连接。
            var master = host.Auth == AuthMode.Key ? "auto" : "no";
            opts.AddRange(["-o", $"ControlMaster={master}", "-o", $"ControlPath={ControlPathFor(host)}", "-o", "ControlPersist=15m"]);
        }
        return opts;
    }

    /// 主连接的保活参数：每 30 秒发心跳，连续 6 次没回应（约 3 分钟）才断开。
    public static List<string> KeepAliveOptions(HostConfig host) =>
        ["-o", $"ControlPersist={host.KeepAlive.ControlPersist()}", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6", "-o", "TCPKeepAlive=yes"];

    public Task<SshResult> RunAsync(HostConfig host, string remoteCommand, string? script, TimeSpan timeout)
    {
        var args = Options(host);
        args.Add(TargetFor(host));
        args.Add(remoteCommand);
        return RunWithProbe(host, args, script, timeout);
    }

    async Task<SshResult> RunWithProbe(HostConfig host, List<string> args, string? script, TimeSpan timeout)
    {
        var result = await RunProcessAsync(SshPath, args, SshCommon.FullScript(host, script), timeout);
        // 开着 ControlPersist 时，OpenSSH 把 ProxyCommand（跳板机那一跳）的 stderr 丢到 /dev/null，
        // 跳板机出错时什么提示都没有。这时不复用连接再试一次（只握手、不执行脚本），拿到真正的错误信息。
        if (result.Status == 255 && !result.TimedOut && result.Stderr.Trim().Length == 0 && SshHosts.JumpChain(host).Count > 0)
        {
            List<string> probe = [.. ConfigArgs(host), "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "LogLevel=ERROR",
                                  "-o", "ControlMaster=no", "-o", "ControlPath=none", "-T", TargetFor(host), "true"];
            var r = await RunProcessAsync(SshPath, probe, null, TimeSpan.FromSeconds(20));
            if (r.Status != 0) result = result with { Stderr = r.Stderr };
        }
        return result;
    }

    public static async Task<SshResult> RunProcessAsync(string path, IEnumerable<string> args, string? stdin, TimeSpan timeout,
                                                        IDictionary<string, string>? env = null)
    {
        var sw = Stopwatch.StartNew();
        var psi = new ProcessStartInfo(path)
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
        };
        foreach (var a in args) psi.ArgumentList.Add(a);
        psi.Environment["LC_ALL"] = "C";
        if (env != null) foreach (var (k, v) in env) psi.Environment[k] = v;

        Process p;
        try { p = Process.Start(psi)!; }
        catch (Exception e)
        {
            return SshResult.Failure(L("无法启动 ssh：", "Cannot start ssh: ") + e.Message) with { Status = -1 };
        }
        using (p)
        {
            // 分别读取 stdout / stderr，避免管道缓冲区写满导致死锁。
            var outTask = p.StandardOutput.ReadToEndAsync();
            var errTask = p.StandardError.ReadToEndAsync();
            try
            {
                if (stdin != null)
                {
                    var bytes = new UTF8Encoding(false).GetBytes(stdin.Replace("\r\n", "\n"));
                    await p.StandardInput.BaseStream.WriteAsync(bytes);
                    await p.StandardInput.BaseStream.FlushAsync();
                }
                p.StandardInput.Close();
            }
            catch { }

            bool timedOut = false;
            using var cts = new CancellationTokenSource(timeout);
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException)
            {
                timedOut = true;
                try { p.Kill(entireProcessTree: true); } catch { }
            }
            string stdout = "", stderr = "";
            try { stdout = await outTask.WaitAsync(TimeSpan.FromSeconds(3)); } catch { }
            try { stderr = await errTask.WaitAsync(TimeSpan.FromSeconds(3)); } catch { }
            int status = timedOut ? -1 : p.HasExited ? p.ExitCode : -1;
            return new SshResult(stdout, stderr, status, sw.Elapsed.TotalSeconds, timedOut);
        }
    }

    /// 用原生对话框登录：建立一条后台主连接并按设置时长保持，之后的轮询全部复用它。
    /// ssh 需要密码时会以 SSH_ASKPASS 的身份启动本程序（带 SERVERISLAND_ASKPASS=1），由本程序弹窗把输入写到 stdout。
    /// 经跳板机时每一跳的 ssh 都带着自己的 SERVERISLAND_ASKPASS_HOSTID，弹窗写明是哪台机器。
    public Task<string?> LoginAsync(HostConfig host, ILoginPrompter prompter) => Login(host, silent: false);

    /// 后台用记住的密码重新登录：askpass 只用凭据库里的密码，不弹任何窗口。
    public Task<string?> AutoLoginAsync(HostConfig host) => Login(host, silent: true);

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

    async Task<string?> Login(HostConfig host, bool silent)
    {
        if (!SupportsControlMaster)
            return L("系统 ssh 在 Windows 上不能保持登录，请在设置里把 SSH 改为“内置 SSH”", "System ssh can't keep a login on Windows; switch SSH to Built-in in Settings");
        EnsureControlDirectory();
        var exe = Environment.ProcessPath;
        if (exe == null) return L("找不到程序路径", "Cannot find the app executable");
        var token = Guid.NewGuid().ToString("N")[..8];
        var errFile = Path.Combine(ControlDirectory, $"login-{token}.err");
        var session = Path.Combine(ControlDirectory, $"askpass-{token}");
        try
        {
            Directory.CreateDirectory(session);
            File.SetUnixFileMode(session, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
        }
        catch { }

        var (code, err) = await Task.Run(() =>
        {
            var psi = new ProcessStartInfo(SshPath) { UseShellExecute = false, RedirectStandardInput = true };
            foreach (var a in ConfigArgs(host)) psi.ArgumentList.Add(a);
            foreach (var a in KeepAliveOptions(host)) psi.ArgumentList.Add(a);
            foreach (var a in new[] { "-o", "ControlMaster=yes", "-o", $"ControlPath={ControlPathFor(host)}", "-o", "ConnectTimeout=15",
                                      "-o", $"NumberOfPasswordPrompts={(silent ? 1 : 2)}", "-o", "LogLevel=ERROR",
                                      "-E", errFile, "-fN", TargetFor(host) })
                psi.ArgumentList.Add(a);
            psi.Environment["SSH_ASKPASS"] = exe;
            psi.Environment["SSH_ASKPASS_REQUIRE"] = "force";
            psi.Environment["DISPLAY"] = Environment.GetEnvironmentVariable("DISPLAY") ?? ":0";
            psi.Environment[AskPassFlag] = "1";
            psi.Environment[AskPassHost] = host.DisplayName;
            psi.Environment[SshHosts.AskPassHostIdEnv] = host.Id.ToString("D").ToUpperInvariant();
            psi.Environment[AskPassSession] = session;
            if (silent) psi.Environment[AskPassSilent] = "1";
            Process p;
            try { p = Process.Start(psi)!; }
            catch (Exception e) { return (-1, L("无法启动 ssh：", "Cannot start ssh: ") + e.Message); }
            using (p)
            {
                try { p.StandardInput.Close(); } catch { }
                // 用户输入口令需要时间（多跳时要输好几次）。后台主连接 fork 之后前台进程就会退出。
                if (!p.WaitForExit(silent ? 40_000 : 300_000)) { try { p.Kill(); } catch { } }
                string text = "";
                try { text = File.ReadAllText(errFile); } catch { }
                return (p.HasExited ? p.ExitCode : -1, text);
            }
        });

        try
        {
            foreach (var f in Directory.GetFiles(session, "remember-*"))
            {
                if (!Guid.TryParse(Path.GetFileName(f)["remember-".Length..], out var id)) continue;
                lock (_remember) _remember[id] = File.ReadAllText(f).StartsWith('1');
            }
        }
        catch { }
        try { File.Delete(errFile); Directory.Delete(session, true); } catch { }

        if (code == 0) return null;
        var line = err.Split('\n').Select(l => l.Trim()).LastOrDefault(l => l.Length > 0);
        var msg = line ?? L("登录被取消或失败", "Login cancelled or failed");
        // 经跳板机时指明是哪一跳出的问题
        if (SshCommon.JumpProblem(err, host) is { } hop && hop.Message is { Length: > 0 } m) msg = m + (line != null ? $"（{line}）" : "");
        return msg;
    }

    public const string AskPassFlag = "SERVERISLAND_ASKPASS";
    public const string AskPassHost = "SERVERISLAND_ASKPASS_HOST";
    /// 一次登录的临时目录：记录哪台机器已经用过记住的密码（再被问就说明密码错了）、用户是否勾选记住。
    public const string AskPassSession = "SERVERISLAND_ASKPASS_SESSION";
    /// 后台自动重新登录：不弹任何窗口，只用记住的密码。
    public const string AskPassSilent = "SERVERISLAND_ASKPASS_SILENT";

    public async Task<bool> IsLoggedInAsync(HostConfig host)
    {
        if (!SupportsControlMaster) return false;
        var r = await RunProcessAsync(SshPath, [.. ConfigArgs(host), "-o", $"ControlPath={ControlPathFor(host)}", "-O", "check", TargetFor(host)], null, TimeSpan.FromSeconds(5));
        return r.Status == 0;
    }

    public async Task CloseAsync(HostConfig host)
    {
        if (!SupportsControlMaster) return;
        await RunProcessAsync(SshPath, [.. ConfigArgs(host), "-o", $"ControlPath={ControlPathFor(host)}", "-O", "exit", TargetFor(host)], null, TimeSpan.FromSeconds(5));
    }
}
