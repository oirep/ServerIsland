using System.Runtime.InteropServices;
using Avalonia;
using ServerIsland.Core;
using ServerIsland.Core.Ssh;

namespace ServerIsland.Desktop;

static class Program
{
    public static bool Demo { get; private set; }

    [STAThread]
    public static int Main(string[] args)
    {
        // 作为 ssh 的 SSH_ASKPASS 被调用（Linux 上用系统 ssh 登录时）：弹出密码框，结果写到 stdout。
        if (Environment.GetEnvironmentVariable(OpenSshTransport.AskPassFlag) == "1")
        {
            AttachConsoleIfAny();
            return AskPassApp.Run(args);
        }

        bool cli = args.Any(a => a is "--selftest" or "--render-preview" or "--diagnose" or "--dump-scripts" or "--version" or "--help" or "--ui-smoke");
        AppDomain.CurrentDomain.UnhandledException += (_, e) => DebugLog.Log("未处理的异常：" + e.ExceptionObject);
        TaskScheduler.UnobservedTaskException += (_, e) => { DebugLog.Log("后台任务异常：" + e.Exception); e.SetObserved(); };
        if (cli) AttachConsoleIfAny();

        if (args.Contains("--version")) { Console.WriteLine("ServerIsland " + AppInfo.Version); return 0; }
        if (args.Contains("--help"))
        {
            Console.WriteLine("""
                ServerIsland
                  --demo                         演示模式（不连接服务器）
                  --selftest                     解析 / 脚本自检
                  --diagnose <别名> [slurm|pbs|direct|slurm+]   对真实服务器跑一次完整采集并打印
                  --render-preview <目录> [zh|en]  把各个界面渲染成 PNG（演示数据）
                  --dump-scripts <目录>          导出生成的远端脚本（和 Swift 版对比用）
                  --ui-smoke <目录>              用演示数据在真实窗口上走一遍界面并截图（自查用）
                """);
            return 0;
        }

        if (args.Contains("--selftest"))
        {
            DebugLog.Enabled = false;
            return SelfTest.Run() ? 0 : 1;
        }

        if (Index(args, "--dump-scripts") is { } di && di + 1 < args.Length)
        {
            Directory.CreateDirectory(args[di + 1]);
            foreach (var (name, text) in SelfTest.ReferenceScripts()) File.WriteAllText(Path.Combine(args[di + 1], name), text);
            Console.WriteLine("ok");
            return 0;
        }

        if (Index(args, "--diagnose") is { } gi && gi + 1 < args.Length)
        {
            var kindArg = gi + 2 < args.Length ? args[gi + 2] : "direct";
            var kind = kindArg.StartsWith("slurm") ? HostKind.Slurm : kindArg.StartsWith("pbs") ? HostKind.Pbs : HostKind.Direct;
            Diagnose.Run(args[gi + 1], kind, kindArg.EndsWith('+')).GetAwaiter().GetResult();
            return 0;
        }

        if (Index(args, "--render-preview") is { } ri && ri + 1 < args.Length)
        {
            var lang = ri + 2 < args.Length && args[ri + 2] == "en" ? AppLanguage.En : AppLanguage.Zh;
            DebugLog.Enabled = false;
            return Preview.PreviewRenderer.Run(args[ri + 1], lang);
        }

        if (Index(args, "--ui-smoke") is { } ui && ui + 1 < args.Length) Preview.UiSmoke.Directory = args[ui + 1];
        Demo = args.Contains("--demo") || Preview.UiSmoke.Directory != null || Environment.GetEnvironmentVariable("SERVERISLAND_DEMO") == "1";
        if (!Demo && !SingleInstance.TryAcquire()) return 0;   // 已经在运行
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args, Avalonia.Controls.ShutdownMode.OnExplicitShutdown);
        return 0;
    }

    public static AppBuilder BuildAvaloniaApp() => AppBuilder.Configure<App>()
        .UsePlatformDetect()
        .LogToTrace();

    static int? Index(string[] args, string flag) => Array.IndexOf(args, flag) is var i and >= 0 ? i : null;

    /// Windows 的 WinExe 没有控制台：从命令行启动时把输出接到父进程的控制台上。
    static void AttachConsoleIfAny()
    {
        if (!OperatingSystem.IsWindows()) return;
        if (AttachConsole(-1))
        {
            var stdout = new StreamWriter(Console.OpenStandardOutput()) { AutoFlush = true };
            Console.SetOut(stdout);
            Console.SetError(stdout);
        }
        Console.OutputEncoding = System.Text.Encoding.UTF8;
    }

    [DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);
}

public static class AppInfo
{
    public static string Version =>
        typeof(AppInfo).Assembly.GetName().Version is { } v ? $"{v.Major}.{v.Minor}.{v.Build}" : "dev";

    public const string Repo = "https://github.com/zhyan0603/ServerIsland";
    public const string Issues = "https://github.com/zhyan0603/ServerIsland/issues";
}

/// 只允许运行一个实例（两个实例会同时轮询、同时弹窗）。
static class SingleInstance
{
    static Mutex? _mutex;

    public static bool TryAcquire()
    {
        try
        {
            _mutex = new Mutex(true, "ServerIsland-" + Environment.UserName, out bool created);
            return created;
        }
        catch { return true; }
    }
}

/// `--diagnose <别名> [slurm|pbs|direct|slurm+]`：对真实服务器跑一次完整采集并打印（只读）。
static class Diagnose
{
    public static async Task Run(string alias, HostKind kind, bool alsoProcesses)
    {
        var store = new ConfigStore(persist: false);
        var real = new ConfigStore(persist: true);
        store.Settings.SshBackend = Environment.GetEnvironmentVariable("SERVERISLAND_SSH") switch
        {
            "managed" => SshBackend.Managed,
            "openssh" => SshBackend.OpenSsh,
            _ => real.Settings.SshBackend,
        };
        var host = new HostConfig(alias, kind: kind) { SlurmAlsoProcesses = alsoProcesses };
        // 已添加的服务器（按别名或显示名称）：用它的全部连接设置（手动地址、跳板机、认证）。
        if (real.Settings.Hosts.FirstOrDefault(h => h.Alias == alias || h.DisplayName == alias) is { } configured)
        {
            host = configured.Clone();
            host.Kind = kind;
            host.SlurmAlsoProcesses = alsoProcesses;
            Console.WriteLine($"（使用设置里的“{host.DisplayName}”：{SshHosts.Summary(host)}，跳板机 [{string.Join(", ", SshHosts.JumpChain(host).Select(j => j.DisplayName))}]）");
        }
        store.Settings.Hosts = [host];
        var engine = new MonitorEngine(store, ssh: SshCommon.Create(store.Settings.SshBackend), history: new HistoryStore(persist: false));
        Console.WriteLine(await engine.Diagnose(host));
        Console.WriteLine("\n===== 解析结果 =====");
        await engine.PollForDiagnosis(host);
        if (!engine.Snapshots.TryGetValue(host.Id, out var snap)) return;
        Console.WriteLine("health: " + snap.Health);
        Console.WriteLine($"metrics: cpu={snap.Metrics.CpuPercent} cores={snap.Metrics.Cores} load={snap.Metrics.Load1} mem={snap.Metrics.MemoryUsed}/{snap.Metrics.MemoryTotal}");
        foreach (var g in snap.Gpus) Console.WriteLine($"gpu: {g.Index} {g.Name} {g.Utilization}% {g.MemoryUsedMB}/{g.MemoryTotalMB}");
        foreach (var j in snap.Jobs)
        {
            Console.WriteLine($"job: {j.Id} {j.Name} {j.State} {j.Elapsed ?? -1} {j.Detail.Prefix(80)}");
            if (j.Message != null) Console.WriteLine($"     message: {j.Message} progress: {(j.Progress is { } p ? Format.Percent(p) : "-")}");
        }
        Console.WriteLine("warnings: " + string.Join(" | ", snap.Warnings));
        foreach (var d in snap.Disks) Console.WriteLine($"disk: {d.Mount} {Format.Percent(d.Fraction)}");
        var top = await engine.TopProcesses(host) ?? [];
        Console.WriteLine("\n===== 高负载进程（监听候选） =====");
        foreach (var p in top) Console.WriteLine($"{p.Id} {p.Name} {p.CpuPercent ?? 0} {p.GpuMemoryMB ?? 0}");
        var h = await engine.FetchHistory(host);
        Console.WriteLine($"\nhistory: fromServer={h.FromServer} count={h.Entries.Count}");
    }
}
