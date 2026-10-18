using System.Text.Json;

namespace ServerIsland.Core;

/// 本机记录的已结束任务（最近 24 小时）。集群没开 accounting、或者是直连服务器时，"最近 24 小时"就用这里的记录。
public sealed class HistoryStore
{
    readonly Dictionary<Guid, List<HistoryEntry>> _entries = [];
    readonly string _path = Path.Combine(AppPaths.ConfigDirectory, "history.json");
    readonly bool _persist;
    static readonly TimeSpan Window = TimeSpan.FromHours(24);

    public HistoryStore(bool persist = true)
    {
        _persist = persist;
        if (persist && File.Exists(_path))
        {
            try
            {
                var decoded = JsonSerializer.Deserialize<Dictionary<string, List<HistoryEntry>>>(File.ReadAllText(_path), Json.Options);
                foreach (var (k, v) in decoded ?? [])
                    if (Guid.TryParse(k, out var id)) _entries[id] = v;
            }
            catch { }
        }
        Prune();
    }

    public void Record(Guid host, HistoryEntry entry)
    {
        var list = _entries.GetValueOrDefault(host) ?? [];
        list.RemoveAll(e => e.Id == entry.Id);
        list.Insert(0, entry);
        _entries[host] = list.Take(200).ToList();
        Prune();
        Save();
    }

    public List<HistoryEntry> Entries(Guid host)
    {
        var cutoff = DateTime.Now - Window;
        return (_entries.GetValueOrDefault(host) ?? []).Where(e => e.EndedAt > cutoff).ToList();
    }

    void Prune()
    {
        var cutoff = DateTime.Now - Window;
        foreach (var k in _entries.Keys.ToList()) _entries[k] = _entries[k].Where(e => e.EndedAt > cutoff).ToList();
    }

    void Save()
    {
        if (!_persist) return;
        try
        {
            Directory.CreateDirectory(AppPaths.ConfigDirectory);
            var dict = _entries.ToDictionary(kv => kv.Key.ToString("D").ToUpperInvariant(), kv => kv.Value);
            File.WriteAllText(_path, JsonSerializer.Serialize(dict, Json.Options));
        }
        catch { }
    }
}

/// 轻量诊断日志（超过 512KB 自动轮转）。记录轮询结果、任务消失、提醒是否发出以及原因，方便排查"为什么没提醒"。
/// 轻量诊断日志（超过 512KB 轮转成 serverisland.1.log）。超过保留天数（设置 → 通用，默认 7 天）的行自动删除；也可以一键清空。
public static class DebugLog
{
    static readonly object Lock = new();
    public static bool Enabled = true;
    public static string Path => System.IO.Path.Combine(AppPaths.LogDirectory, "serverisland.log");
    public static string RotatedPath => System.IO.Path.ChangeExtension(Path, ".1.log");
    const string Format = "yyyy-MM-dd HH:mm:ss";

    public static void Log(string message)
    {
        if (!Enabled) return;
        var line = $"{DateTime.Now.ToString(Format, System.Globalization.CultureInfo.InvariantCulture)}  {message}\n";
        ThreadPool.QueueUserWorkItem(_ =>
        {
            lock (Lock)
            {
                try
                {
                    Directory.CreateDirectory(AppPaths.LogDirectory);
                    var info = new FileInfo(Path);
                    if (info.Exists && info.Length > 512_000)
                    {
                        File.Delete(RotatedPath);
                        File.Move(Path, RotatedPath);
                    }
                    File.AppendAllText(Path, line);
                }
                catch { }
            }
        });
    }

    /// 删除早于 days 天的行（0 表示永久保留）。
    public static void Prune(int days)
    {
        if (days <= 0) return;
        var now = DateTime.Now;
        var cutoff = now.AddDays(-days);
        ThreadPool.QueueUserWorkItem(_ =>
        {
            lock (Lock)
            {
                foreach (var file in new[] { RotatedPath, Path })
                {
                    try
                    {
                        if (!File.Exists(file)) continue;
                        var text = File.ReadAllText(file);
                        var kept = PruneText(text, cutoff, now);
                        if (kept == text) continue;
                        if (kept.Length == 0) File.Delete(file); else File.WriteAllText(file, kept);
                    }
                    catch { }
                }
            }
        });
    }

    /// 只保留 cutoff 之后的行；没有时间戳的行（多行消息的后续行）跟随上一行。
    /// 旧版本的时间戳没有年份（"MM-dd HH:mm:ss"），按今年算，晚于现在就算去年。
    public static string PruneText(string text, DateTime cutoff, DateTime now)
    {
        var inv = System.Globalization.CultureInfo.InvariantCulture;
        var style = System.Globalization.DateTimeStyles.None;
        bool keep = true;
        var outLines = new List<string>();
        foreach (var line in text.Split('\n'))
        {
            if (line.Length >= 19 && DateTime.TryParseExact(line[..19], Format, inv, style, out var d)) keep = d >= cutoff;
            else if (line.Length >= 16 && line[14..16] == "  " && DateTime.TryParseExact($"{now.Year}-{line[..14]}", Format, inv, style, out var o))
            {
                if (o > now.AddDays(1)) o = o.AddYears(-1);
                keep = o >= cutoff;
            }
            if (keep) outLines.Add(line);
        }
        var s = string.Join("\n", outLines);
        return s.Trim().Length == 0 ? "" : s;
    }

    /// 清空全部诊断日志。
    public static void Clear()
    {
        lock (Lock)
        {
            try { File.Delete(RotatedPath); } catch { }
            try { File.Delete(Path); } catch { }
        }
    }

    /// 两个日志文件加起来的大小（字节）。
    public static long Size => new[] { Path, RotatedPath }.Select(f => File.Exists(f) ? new FileInfo(f).Length : 0).Sum();
}
