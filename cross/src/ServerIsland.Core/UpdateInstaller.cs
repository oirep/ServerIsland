using System.Diagnostics;
using System.Formats.Tar;
using System.IO.Compression;
using System.Net.Http;
using System.Reflection;
using System.Security.Cryptography;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 自动更新（Windows / Linux）：下载 zip / tar.gz → 核对 SHA-256（GitHub 给每个附件的 digest）→ 解压到临时目录 →
/// 把程序所在文件夹里的旧文件改名成 `.old`、新文件移进来（Windows 不让覆盖正在运行的 exe，但允许改名；Linux 直接替换）
/// → 界面启动新程序（`--after-update <旧进程 PID>`，等旧进程退出后再运行）并退出。新程序启动时删掉 `.old`。
/// Mac 上的试用版不自动更新（Mac 的正式版是 Swift 版，有自己的 UpdateInstaller）。
public static class UpdateInstaller
{
    /// 程序的可执行文件名（和安装包里的一致）。
    public static string ExeName => OperatingSystem.IsWindows() ? "ServerIsland.exe" : "ServerIsland";

    /// 正在运行的程序所在的文件夹；不是发布的单文件程序（dotnet run、调试构建）时为 null。
    public static string? InstallDirectory
    {
        get
        {
            // 单文件发布时程序集没有自己的路径（Location 为空）
            if (!string.IsNullOrEmpty(Assembly.GetEntryAssembly()?.Location)) return null;
            var exe = Environment.ProcessPath;
            if (exe == null || !string.Equals(Path.GetFileName(exe), ExeName, StringComparison.OrdinalIgnoreCase)) return null;
            return Path.GetDirectoryName(exe);
        }
    }

    /// 做不到自动替换时返回原因（界面上改为提供下载页面）。
    public static string? UnsupportedReason(UpdateChecker.Release r)
    {
        if (!OperatingSystem.IsWindows() && !OperatingSystem.IsLinux())
            return L("Mac 上的试用版不自动更新", "The Mac preview build doesn't update itself");
        if (r.Digest == null || r.DownloadUrl == r.PageUrl)
            return L("这个版本的安装包没有校验信息，请手动下载", "This release has no checksum; please download it manually");
        if (InstallDirectory is not { } dir) return L("开发版本，不自动更新", "Development build; not updating automatically");
        try
        {
            var probe = Path.Combine(dir, ".serverisland-write-test");
            File.WriteAllText(probe, "");
            File.Delete(probe);
        }
        catch { return L($"没有权限替换 {dir} 里的程序，请手动下载安装", $"No permission to replace the program in {dir}; please install it manually"); }
        return null;
    }

    /// 下载用的临时目录（每次更新前清空）。
    public static string WorkDirectory => Path.Combine(Path.GetTempPath(), "ServerIsland-update-" + Environment.UserName);

    /// 下载、核对、解压，返回解压后的目录。
    public static async Task<string> DownloadAndStageAsync(UpdateChecker.Release r, Action<double?> progress)
    {
        var work = WorkDirectory;
        if (Directory.Exists(work)) Directory.Delete(work, true);
        Directory.CreateDirectory(work);
        var file = Path.Combine(work, r.DownloadUrl.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) ? "update.zip" : "update.tar.gz");
        using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd($"ServerIsland/{UpdateChecker.CurrentVersion}");
            using var resp = await http.GetAsync(r.DownloadUrl, HttpCompletionOption.ResponseHeadersRead);
            if (!resp.IsSuccessStatusCode) throw new Exception(L($"下载失败（HTTP {(int)resp.StatusCode}）", $"Download failed (HTTP {(int)resp.StatusCode})"));
            var total = resp.Content.Headers.ContentLength ?? r.Size;
            await using var src = await resp.Content.ReadAsStreamAsync();
            await using var dst = File.Create(file);
            var buf = new byte[1 << 16];
            long done = 0;
            int n;
            while ((n = await src.ReadAsync(buf)) > 0)
            {
                await dst.WriteAsync(buf.AsMemory(0, n));
                done += n;
                progress(total > 0 ? (double)done / total.Value : null);
            }
        }
        return Stage(file, r.Digest ?? "", Path.Combine(work, "new"));
    }

    /// 核对并解压安装包，检查里面有程序。`--test-update` 也直接调用它。
    public static string Stage(string archive, string digest, string into)
    {
        if (!string.Equals(Sha256(archive), digest, StringComparison.OrdinalIgnoreCase))
            throw new Exception(L("下载的文件校验不对，已放弃更新", "The download failed its checksum; update cancelled"));
        Directory.CreateDirectory(into);
        try
        {
            if (archive.EndsWith(".zip", StringComparison.OrdinalIgnoreCase)) ZipFile.ExtractToDirectory(archive, into, overwriteFiles: true);
            else
            {
                using var fs = File.OpenRead(archive);
                using var gz = new GZipStream(fs, CompressionMode.Decompress);
                TarFile.ExtractToDirectory(gz, into, overwriteFiles: true);
            }
        }
        catch (Exception e) { throw new Exception(L("解压安装包失败：", "Couldn't extract the update: ") + e.Message); }
        if (!File.Exists(Path.Combine(into, ExeName)))
            throw new Exception(L($"安装包里没有 {ExeName}", $"{ExeName} is missing from the update"));
        return into;
    }

    /// 记下这次更新改名出来的 `.old` 文件（每行一个文件名），下次启动时只删这些。
    public const string OldListName = ".serverisland-update-old";
    /// 早期版本更新时没有记录：只删安装包里这几个文件的 `.old`。
    static readonly string[] PackageFiles = ["ServerIsland.exe", "ServerIsland", "LICENSE.txt", "serverisland.desktop", "AppIcon.png"];

    /// 把解压出来的文件（只有一层）换进程序所在的文件夹：已有的旧文件先改名成 `.old`。返回新程序的路径。
    /// 中途失败（包括设置执行权限失败）时把已经换过的全部改回去。`testHook` 只给自检用：
    /// 旧文件改名后以 ("backup", 目标) 调用、新文件移进来后以 ("moved", 目标) 调用，用来模拟失败。
    public static string Apply(string staged, string installDir, Action<string, string>? testHook = null)
    {
        // 动手之前就登记：Dest 原来不存在、或者已经改名成 Old，所以回滚时 Dest 上有什么都是这次放上去的。
        // （跨磁盘的 File.Move 是先复制再删除，可能目标已经写出来了才报错。）
        var done = new List<(string Dest, string? Old)>();
        var exe = Path.Combine(installDir, ExeName);
        try
        {
            foreach (var src in Directory.GetFiles(staged))
            {
                var dest = Path.Combine(installDir, Path.GetFileName(src));
                string? old = null;
                if (File.Exists(dest))
                {
                    old = dest + ".old";
                    if (File.Exists(old)) File.Delete(old);
                    File.Move(dest, old);
                }
                done.Add((dest, old));
                testHook?.Invoke("backup", dest);
                File.Move(src, dest);
                testHook?.Invoke("moved", dest);
            }
            if (!OperatingSystem.IsWindows())
                File.SetUnixFileMode(exe, UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute
                                          | UnixFileMode.GroupRead | UnixFileMode.GroupExecute | UnixFileMode.OtherRead | UnixFileMode.OtherExecute);
            File.WriteAllLines(Path.Combine(installDir, OldListName), done.Where(d => d.Old != null).Select(d => Path.GetFileName(d.Old!)));
        }
        catch (Exception e)
        {
            var stuck = new List<string>();
            foreach (var (dest, old) in Enumerable.Reverse(done))
            {
                try
                {
                    if (File.Exists(dest)) File.Delete(dest);
                    if (old != null) File.Move(old, dest);
                }
                catch (Exception re)
                {
                    stuck.Add($"{Path.GetFileName(dest)}（{re.Message}）");
                    DebugLog.Log($"自动更新：恢复 {dest} 失败：{re.Message}");
                }
            }
            throw new Exception(L("替换程序文件失败：", "Couldn't replace the program files: ") + e.Message
                + (stuck.Count == 0 ? "" : L("；以下文件没能恢复，请手动下载安装：", "; these files couldn't be restored, please reinstall manually: ")
                                           + string.Join("、", stuck)));
        }
        return exe;
    }

    /// 启动时删掉上次更新留下的 `.old` 文件（只删记录里的，文件夹里别的 `.old` 不动）和临时目录。
    public static void CleanupOld(string? installDir = null)
    {
        if ((installDir ?? InstallDirectory) is not { } dir) return;
        var list = Path.Combine(dir, OldListName);
        IEnumerable<string> names;
        try { names = File.Exists(list) ? File.ReadAllLines(list) : PackageFiles.Select(f => f + ".old"); }
        catch { names = []; }
        foreach (var name in names)
        {
            // 记录里只该有文件名；不像的（带路径、不是 .old）跳过
            if (name.Length == 0 || name != Path.GetFileName(name) || !name.EndsWith(".old", StringComparison.Ordinal)) continue;
            try { File.Delete(Path.Combine(dir, name)); } catch { }
        }
        try { File.Delete(list); } catch { }
        try { if (Directory.Exists(WorkDirectory)) Directory.Delete(WorkDirectory, true); } catch { }
    }

    /// 新程序启动时：等旧进程退出（最多 30 秒），再去抢"只运行一个"的锁。
    public static void WaitForExit(int pid)
    {
        try { using var p = Process.GetProcessById(pid); p.WaitForExit(30_000); }
        catch { }   // 已经退出了
    }

    public static string Sha256(string path)
    {
        using var fs = File.OpenRead(path);
        return Convert.ToHexString(SHA256.HashData(fs)).ToLowerInvariant();
    }
}

/// `--test-update <目录>`：在临时目录里走一遍自动更新，不碰真正的程序（和 Mac 版的同名命令对应）。
public static class UpdateInstallerTest
{
    public static bool Run(string dir)
    {
        var ok = true;
        void Check(bool c, string name) { Console.WriteLine((c ? "✓ " : "✗ ") + name); if (!c) ok = false; }
        if (Directory.Exists(dir)) Directory.Delete(dir, true);
        var exe = UpdateInstaller.ExeName;
        var pkg = Path.Combine(dir, "pkg");
        Directory.CreateDirectory(pkg);
        File.WriteAllText(Path.Combine(pkg, exe), "new");
        File.WriteAllText(Path.Combine(pkg, "LICENSE.txt"), "new license");
        var zip = Path.Combine(dir, "update.zip");
        System.IO.Compression.ZipFile.CreateFromDirectory(pkg, zip);
        var tgz = Path.Combine(dir, "update.tar.gz");
        using (var fs = File.Create(tgz))
        using (var gz = new System.IO.Compression.GZipStream(fs, System.IO.Compression.CompressionLevel.Optimal))
            System.Formats.Tar.TarFile.CreateFromDirectory(pkg, gz, includeBaseDirectory: false);

        try { UpdateInstaller.Stage(zip, new string('0', 64), Path.Combine(dir, "bad")); Check(false, "校验值不对时拒绝"); }
        catch (Exception e) { Check(true, "校验值不对时拒绝：" + e.Message); }

        foreach (var archive in new[] { zip, tgz })
        {
            var kind = Path.GetFileName(archive);
            var install = Path.Combine(dir, "install-" + kind);
            Directory.CreateDirectory(install);
            File.WriteAllText(Path.Combine(install, exe), "old");
            File.WriteAllText(Path.Combine(install, "LICENSE.txt"), "old license");
            File.WriteAllText(Path.Combine(install, "keep.txt"), "keep");
            var staged = UpdateInstaller.Stage(archive, UpdateInstaller.Sha256(archive), Path.Combine(dir, "new-" + kind));
            var result = UpdateInstaller.Apply(staged, install);
            Check(File.ReadAllText(result) == "new" && File.ReadAllText(Path.Combine(install, "LICENSE.txt")) == "new license"
                  && File.ReadAllText(Path.Combine(install, exe + ".old")) == "old" && File.ReadAllText(Path.Combine(install, "keep.txt")) == "keep",
                  $"{kind}：新文件换进去，旧文件改名成 .old，其它文件不动");
            if (!OperatingSystem.IsWindows())
                Check(File.GetUnixFileMode(result).HasFlag(UnixFileMode.UserExecute), $"{kind}：新程序可以执行");
            File.WriteAllText(Path.Combine(install, "notes.txt.old"), "user");
            UpdateInstaller.CleanupOld(install);
            Check(!File.Exists(Path.Combine(install, exe + ".old")) && !File.Exists(Path.Combine(install, "LICENSE.txt.old"))
                  && File.Exists(Path.Combine(install, "notes.txt.old")) && !File.Exists(Path.Combine(install, UpdateInstaller.OldListName)),
                  $"{kind}：下次启动时只删这次更新留下的 .old，别的 .old 不动");
        }

        // 中途失败：旧文件已经改名、新文件还没移进来时出错，所有文件都要恢复原样
        {
            var install = Path.Combine(dir, "install-fail");
            Directory.CreateDirectory(install);
            File.WriteAllText(Path.Combine(install, exe), "old");
            File.WriteAllText(Path.Combine(install, "LICENSE.txt"), "old license");
            var staged = UpdateInstaller.Stage(zip, UpdateInstaller.Sha256(zip), Path.Combine(dir, "new-fail"));
            var second = Directory.GetFiles(staged).Select(Path.GetFileName).Order(StringComparer.Ordinal).Last()!;
            // backup：旧文件刚改名、新文件还没移进来；moved：新文件已经写到目标位置，移动却报错（跨磁盘移动时会这样）
            foreach (var step in new[] { "backup", "moved" })
            {
                var staged2 = step == "backup" ? staged : UpdateInstaller.Stage(zip, UpdateInstaller.Sha256(zip), Path.Combine(dir, "new-fail-" + step));
                try
                {
                    UpdateInstaller.Apply(staged2, install, (s, d) => { if (s == step && Path.GetFileName(d) == second) throw new IOException("simulated"); });
                    Check(false, $"替换中途失败（{step}）时报错");
                }
                catch (Exception e) { Check(e.Message.Contains("simulated") && !e.Message.Contains("没能恢复"), $"替换中途失败（{step}）时报错：" + e.Message); }
                Check(File.ReadAllText(Path.Combine(install, exe)) == "old" && File.ReadAllText(Path.Combine(install, "LICENSE.txt")) == "old license"
                      && Directory.GetFiles(install, "*.old").Length == 0, $"替换中途失败（{step}）：已换的和刚改名的文件都恢复原样");
            }
        }

        // 早期版本更新时没有记录：只删安装包里那几个文件的 .old
        {
            var install = Path.Combine(dir, "install-legacy");
            Directory.CreateDirectory(install);
            File.WriteAllText(Path.Combine(install, exe + ".old"), "old");
            File.WriteAllText(Path.Combine(install, "photo.jpg.old"), "user");
            UpdateInstaller.CleanupOld(install);
            Check(!File.Exists(Path.Combine(install, exe + ".old")) && File.Exists(Path.Combine(install, "photo.jpg.old")),
                  "没有记录时（旧版本更新过来）：只删程序自己的 .old");
        }

        // 正在运行的程序也能换掉（Windows 上靠改名；Linux / macOS 上直接替换）。Windows 上用系统自带的 ping.exe 的副本当"正在运行的程序"
        if (OperatingSystem.IsWindows() && File.Exists(Path.Combine(Environment.SystemDirectory, "PING.EXE")))
        {
            var install = Path.Combine(dir, "install-running");
            Directory.CreateDirectory(install);
            File.Copy(Path.Combine(Environment.SystemDirectory, "PING.EXE"), Path.Combine(install, exe));
            using var running = Process.Start(new ProcessStartInfo(Path.Combine(install, exe), "-n 5 127.0.0.1") { UseShellExecute = false, RedirectStandardOutput = true });
            Thread.Sleep(300);
            var staged = UpdateInstaller.Stage(zip, UpdateInstaller.Sha256(zip), Path.Combine(dir, "new-running"));
            UpdateInstaller.Apply(staged, install);
            Check(!running!.HasExited && File.ReadAllText(Path.Combine(install, exe)) == "new", "替换正在运行的程序：旧进程不受影响，文件已是新版");
            running.Kill();
        }
        else if (!OperatingSystem.IsWindows())
        {
            var install = Path.Combine(dir, "install-running");
            Directory.CreateDirectory(install);
            File.WriteAllText(Path.Combine(install, exe), "#!/bin/sh\nsleep 3\n");
            File.SetUnixFileMode(Path.Combine(install, exe), UnixFileMode.UserRead | UnixFileMode.UserWrite | UnixFileMode.UserExecute);
            using var running = Process.Start(Path.Combine(install, exe));
            Thread.Sleep(200);
            var staged = UpdateInstaller.Stage(tgz, UpdateInstaller.Sha256(tgz), Path.Combine(dir, "new-running"));
            UpdateInstaller.Apply(staged, install);
            Check(!running.HasExited && File.ReadAllText(Path.Combine(install, exe)) == "new", "替换正在运行的程序：旧进程不受影响，文件已是新版");
            running.Kill();
        }

        using (var sleeper = Process.Start(OperatingSystem.IsWindows() ? "ping" : "sleep", OperatingSystem.IsWindows() ? "-n 2 127.0.0.1" : "1"))
        {
            var t0 = DateTime.Now;
            UpdateInstaller.WaitForExit(sleeper.Id);
            Check(sleeper.HasExited && (DateTime.Now - t0).TotalSeconds >= 0.5, $"新程序等旧进程退出（等了 {(DateTime.Now - t0).TotalSeconds:0.0} 秒）");
        }
        return ok;
    }
}
