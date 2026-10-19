using System.Diagnostics;
using System.Text.Json;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 与 Mac 使用相同的本机任务协议；不会连接 SSH 或写入远端。
public static class LocalTaskStore
{
    static readonly Dictionary<string, DateTime> ObservedExits = [];
    public sealed record Record(RemoteJob Job, string Host, string ActionID, DateTime Updated, DateTime Started);
    public static string DirectoryPath => Path.Combine(
        Environment.GetEnvironmentVariable("SERVERISLAND_LOCAL_STATE_DIR")
            ?? Path.Combine(AppPaths.Home, ".serverisland"), "local", "progress");
    public static HostConfig LocalHost => new() {
        Id = HostConfig.LocalTaskID, Alias = "local-tasks", DisplayName = L("本地任务", "Local tasks"),
        ShowCPU = false, ShowMemory = false, ShowGPU = false, ShowDisk = false,
        WatchJobs = false, ReadProgressFiles = false
    };
    static string Text(JsonElement o, string key) =>
        o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    static double? Number(JsonElement o, string key) =>
        o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.Number
            && v.TryGetDouble(out var n) && double.IsFinite(n) ? n : null;
    static bool Alive(int pid) {
        try { using var process = Process.GetProcessById(pid); return !process.HasExited; }
        catch { return false; }
    }
    public static List<Record> Read(string? directory = null, DateTime? now = null)
    {
        var clock = now ?? DateTime.UtcNow;
        var records = new List<Record>();
        string[] files;
        try { files = Directory.GetFiles(directory ?? DirectoryPath, "*.json"); }
        catch { return records; }
        foreach (var path in files)
        {
            try
            {
                var info = new FileInfo(path);
                if (info.Length > 4096 || info.LinkTarget != null) continue;
                using var doc = JsonDocument.Parse(File.ReadAllText(path));
                var obj = doc.RootElement;
                if (!obj.TryGetProperty("deployment", out var d) ||
                    !d.TryGetProperty("local", out var local) || local.ValueKind != JsonValueKind.True) continue;
                var run = Text(d, "run_id");
                if (!Guid.TryParse(run, out _)) continue;
                if (Number(obj, "updated") is not double updated || Number(d, "started") is not double started) continue;
                var date = DateTime.UnixEpoch.AddSeconds(updated);
                var status = Text(obj, "status");
                var state = status switch {
                    "done" => JobState.Completed, "failed" => JobState.Failed,
                    "unknown" => JobState.Other, _ => JobState.Running
                };
                var message = Text(obj, "message");
                if (state == JobState.Running && (clock - date).TotalSeconds > 15
                    && Number(d, "pid") is double pid && (pid <= 0 || (pid <= int.MaxValue && !Alive((int)pid))))
                {
                    state = JobState.Other;
                    message = L("监控进程已退出，执行结果未知", "Monitor exited; result unknown");
                }
                var job = new RemoteJob("local:" + run, Text(obj, "name"), state, JobSource.ProgressFile) {
                    Progress = Number(obj, "progress") is double p ? Math.Clamp(p, 0, 1) : null,
                    Message = message, Detail = L("本机记录 · ", "Local record · ") + message
                };
                if (!state.IsActive())
                {
                    if (status == "running")
                    {
                        if (!ObservedExits.TryGetValue(run, out var end)) ObservedExits[run] = end = clock;
                        job.ProgressEndedAt = end;
                    }
                    else job.ProgressEndedAt = Number(d, "finished") is double completedAt
                        ? DateTime.UnixEpoch.AddSeconds(completedAt) : date;
                }
                records.Add(new(job, Text(d, "host"), Text(d, "action_id"), date, DateTime.UnixEpoch.AddSeconds(started)));
            }
            catch { /* 单个坏文件不影响其它任务。 */ }
        }
        var ended = new HashSet<string>();
        return records.OrderByDescending(r => r.Started).Where(r => r.Job.State.IsActive()
            || ended.Add(r.Host + "|" + (r.ActionID.Length == 0 ? r.Job.Name : r.ActionID))).ToList();
    }
    public static Guid HostID(Record record, IEnumerable<HostConfig> hosts) =>
        hosts.FirstOrDefault(h => h.Id.ToString().Equals(record.Host, StringComparison.OrdinalIgnoreCase)
            || h.Alias == record.Host)?.Id ?? HostConfig.LocalTaskID;

    /// 本机详情与 Mac 版使用相同的 run_id 文件，不把本机路径交给 SSH。
    public static JobDetail Detail(RemoteJob job, string? directory = null)
    {
        var detail = new JobDetail();
        detail.Fields.Add((L("名称", "Name"), job.Name));
        detail.Fields.Add((L("进度说明", "Progress"), job.Message ?? job.State.Label()));
        if (!job.Id.StartsWith("local:") || !Guid.TryParse(job.Id[6..], out var id)) return detail;
        var root = Path.GetDirectoryName(directory ?? DirectoryPath)!;
        var stages = new List<string>();
        try
        {
            var file = Path.Combine(root, "deployments", id.ToString("N") + ".json");
            if (new FileInfo(file).Length <= 256 * 1024)
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                var d = doc.RootElement.GetProperty("deployment");
                if (Number(d, "started") is double start)
                    detail.Fields.Add((L("开始时间", "Started"), DateTime.UnixEpoch.AddSeconds(start).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")));
                if ((Number(d, "finished") ?? (Text(doc.RootElement, "status") != "running"
                    ? Number(doc.RootElement, "updated") : null)) is double end)
                    detail.Fields.Add((L("完成时间", "Finished"), DateTime.UnixEpoch.AddSeconds(end).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")));
                if (d.TryGetProperty("timeline", out var timeline))
                    foreach (var stage in timeline.EnumerateArray())
                        stages.Add($"[{Number(stage, "index")}/{Number(stage, "total")}] {Text(stage, "name")} · "
                            + Format.Duration(Number(stage, "elapsed") ?? Number(d, "stage_elapsed") ?? 0));
            }
        }
        catch { /* 旧任务可能只有摘要，仍可展示其余详情。 */ }
        var log = Path.Combine(root, "logs", id.ToString("N") + ".log");
        detail.Stdout.Path = log;
        try
        {
            using var input = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            var start = Math.Max(0, input.Length - 32768);
            input.Seek(start, SeekOrigin.Begin);
            using var reader = new StreamReader(input);
            if (start > 0) reader.ReadLine();
            detail.Stdout.Lines = reader.ReadToEnd().Split('\n').TakeLast(80).ToList();
        }
        catch { detail.Stdout.Note = L("等待脚本输出；旧版任务没有保存日志。", "Waiting for output; older tasks have no saved log."); }
        if (stages.Count > 0) detail.Stdout.Lines = new[] { L("—— 阶段记录 ——", "—— Stages ——") }
            .Concat(stages).Concat(new[] { L("—— 脚本输出 ——", "—— Script output ——") }).Concat(detail.Stdout.Lines).ToList();
        return detail;
    }
}
