using System.Reflection;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 两端嵌入同一个采集文件，远端只经现有 SSH stdin 临时执行。
public static class DockerMonitor
{
    public static string Source
    {
        get
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("docker-monitor.py")
                ?? throw new InvalidOperationException("Missing embedded Docker collector");
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
    }
    public static string Script => "python3 - <<'SI_DOCKER_PY'\n" + Source + "\nSI_DOCKER_PY";
    public static string ListScript => "SI_DOCKER_LIST_ONLY=1 " + Script;
    public static string? LogScript(string container, int tail) => Regex.IsMatch(container, @"\A[a-fA-F0-9]{12,64}\z")
        ? "SI_DOCKER_LOG_CONTAINER=" + RemoteScript.ShellQuote(container) + $" SI_DOCKER_LOG_TAIL={(tail == 500 ? 500 : 200)} " + Script : null;
    public static string? DetailScript(string container) => Regex.IsMatch(container, @"\A[a-fA-F0-9]{12,64}\z")
        ? "SI_DOCKER_DETAIL_CONTAINER=" + RemoteScript.ShellQuote(container) + " " + Script : null;
}

/// 容器常驻运行不计入作业队列，也不触发计算任务完成提醒。
public sealed class DockerSnapshot
{
    public List<DockerContainer> Containers { get; set; } = [];
    public int Total { get; set; }
    public int Running { get; set; }
    public bool Truncated { get; set; }
    public bool SampleLimited { get; set; }
    public string? Socket { get; set; }
    public string? Version { get; set; }
    public string? Error { get; set; }
    public double? ListedAt { get; set; }
    public bool? ListOnly { get; set; }

    public static DockerSnapshot Parse(IEnumerable<string> lines, DockerSnapshot? previous = null)
    {
        var data = lines.ToArray();
        DockerSnapshot snapshot;
        try
        {
            snapshot = JsonSerializer.Deserialize<DockerSnapshot>(data.LastOrDefault(x => x.StartsWith('{')) ?? "", Json.Options)!;
            if (snapshot == null || snapshot.Containers == null) throw new JsonException();
        }
        catch (JsonException)
        {
            return new() { Error = data.Any(x => x.Contains("python3") && (x.Contains("not found") || x.Contains("未找到"))) ? "python_missing" : "invalid_response" };
        }
        // 只读列表快刷与全量资源采样可交错返回，不能回滚最新容器状态。
        if (snapshot.Error == null && snapshot.ListedAt is { } time && previous?.ListedAt is { } before && time < before)
        {
            var samples = snapshot.Containers;
            snapshot.Containers = previous.Containers.Select(current =>
            {
                var sample = samples.FirstOrDefault(item => item.Id == current.Id && item.State == current.State);
                return sample != null && (sample.SampledAt ?? 0) > (current.SampledAt ?? 0)
                    ? sample.WithListFields(current) : Json.Clone(current);
            }).ToList();
            snapshot.Total = previous.Total; snapshot.Running = previous.Running;
            snapshot.Truncated = previous.Truncated; snapshot.ListedAt = previous.ListedAt;
        }
        else if (snapshot.ListOnly == true)
        {
            snapshot.Containers = snapshot.Containers.Select(item =>
            {
                var old = previous?.Containers.FirstOrDefault(value => value.Id == item.Id);
                if (old == null) return item;
                if (item.State == "running" && old.State == item.State) return old.WithListFields(item);
                item.UpdatedAt = Math.Max(old.UpdatedAt ?? 0, item.State == old.State ? (item.UpdatedAt ?? 0) : (snapshot.ListedAt ?? 0));
                return item;
            }).ToList();
        }
        // 只有连续有效样本才计算速率，计数器回退不伪造负数或零。
        for (int index = 0; index < snapshot.Containers.Count; index++)
        {
            var item = snapshot.Containers[index];
            var newest = previous?.Containers.FirstOrDefault(x => x.Id == item.Id);
            if (item.State == "running" && newest?.State == "running" && newest.SampledAt is { } newestTime
                && item.SampledAt is { } itemTime && newestTime > itemTime)
            {
                snapshot.Containers[index] = newest;
                continue;
            }
            if (previous?.Containers.FirstOrDefault(x => x.Id == item.Id)?.UpdatedAt is { } oldUpdate)
                item.UpdatedAt = Math.Max(item.UpdatedAt ?? item.CreatedAt ?? 0, oldUpdate);
            var old = previous?.Containers.FirstOrDefault(x => x.Id == item.Id && x.State == "running" && x.StatsError == null);
            if (item.State != "running" || item.StatsError != null || old == null || item.SampledAt is not { } currentTime || old.SampledAt is not { } oldTime || currentTime <= oldTime) continue;
            double? Rate(double? value, double? before) => value is { } v && before is { } b && v >= b ? (v - b) / (currentTime - oldTime) : null;
            item.RxRate = Rate(item.NetworkRx, old.NetworkRx);
            item.TxRate = Rate(item.NetworkTx, old.NetworkTx);
            item.ReadRate = Rate(item.BlockRead, old.BlockRead);
            item.WriteRate = Rate(item.BlockWrite, old.BlockWrite);
        }
        return snapshot;
    }

    public static string ErrorText(string code) => code switch
    {
        "container_missing" => L("容器已移除或不可见", "Container was removed or is no longer visible"),
        "invalid_container" => L("容器标识无效或 Docker 监控已关闭", "Invalid container ID or Docker monitoring is disabled"),
        "permission_denied" => L("SSH 用户没有读取 Docker socket 的权限", "SSH user cannot access the Docker socket"),
        "socket_missing" => L("未找到 Docker socket", "Docker socket not found"),
        "python_missing" => L("服务器缺少 python3，无法采集 Docker 指标", "python3 is required on the server for Docker metrics"),
        "unsupported_endpoint" => L("DOCKER_HOST 需要使用 unix:// socket", "DOCKER_HOST must use a unix:// socket"),
        "timeout" => L("Docker 指标采集超时", "Docker metrics timed out"),
        "daemon_unavailable" => L("无法连接 Docker daemon", "Cannot connect to the Docker daemon"),
        _ => L("Docker API 返回了无法识别的数据", "Unrecognized Docker API response"),
    };
}

public sealed class DockerContainer
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string Image { get; set; } = "";
    public string State { get; set; } = "unknown";
    public string Status { get; set; } = "";
    public string Health { get; set; } = "";
    public List<string> Ports { get; set; } = [];
    public string ComposeProject { get; set; } = "";
    public string ComposeService { get; set; } = "";
    public double? CpuPercent { get; set; }
    public int? OnlineCPUs { get; set; }
    public double? MemoryUsed { get; set; }
    public double? MemoryLimit { get; set; }
    public double? NetworkRx { get; set; }
    public double? NetworkTx { get; set; }
    public double? BlockRead { get; set; }
    public double? BlockWrite { get; set; }
    public int? Pids { get; set; }
    public double? SampledAt { get; set; }
    public string? StatsError { get; set; }
    public double? RxRate { get; set; }
    public double? TxRate { get; set; }
    public double? ReadRate { get; set; }
    public double? WriteRate { get; set; }
    public double? CreatedAt { get; set; }
    public double? UpdatedAt { get; set; }
    public double? CpuLimitCores { get; set; }
    public double? MemoryConfiguredLimit { get; set; }
    public bool? LimitsRead { get; set; }
    public string? LimitsError { get; set; }
    public List<string>? Cmd { get; set; }
    public List<string>? Entrypoint { get; set; }
    // 列表元信息更新不触碰资源采样时间或速率。
    public DockerContainer WithListFields(DockerContainer item)
    {
        var result = Json.Clone(this);
        result.Name = item.Name; result.Image = item.Image; result.State = item.State;
        result.Status = item.Status; result.Health = item.Health; result.Ports = item.Ports;
        result.ComposeProject = item.ComposeProject; result.ComposeService = item.ComposeService;
        result.CreatedAt = item.CreatedAt;
        result.UpdatedAt = Math.Max(UpdatedAt ?? 0, item.UpdatedAt ?? item.CreatedAt ?? 0);
        return result;
    }
    [JsonIgnore] public bool IsStopped => State is not ("running" or "restarting" or "paused");
    [JsonIgnore] public string CommandTitle => Cmd?.Count > 0 ? "CMD" : "ENTRYPOINT";
    [JsonIgnore] public List<string>? CommandArguments => Cmd?.Count > 0 ? Cmd : Entrypoint;
    [JsonIgnore] public double? MemoryCapacity
    {
        get
        {
            var values = new[] { MemoryConfiguredLimit, MemoryLimit }.Where(x => x is > 0).Select(x => x!.Value).ToArray();
            return values.Length == 0 ? null : values.Min();
        }
    }
    // 有限额时按容器容量，未设限时沿用 Docker 单核 100%，文本与条形图同源。
    [JsonIgnore] public double? CpuUsagePercent => CpuPercent is { } p ? p / (CpuLimitCores is > 0 ? CpuLimitCores.Value : 1) : null;
    [JsonIgnore] public double? MemoryFraction => MemoryUsed is { } u && MemoryCapacity is { } capacity ? Math.Clamp(u / capacity, 0, 1) : null;
    [JsonIgnore] public double? CpuFraction => CpuUsagePercent is { } p ? Math.Clamp(p / 100, 0, 1) : null;
    [JsonIgnore] public double? ResourceFraction => CpuFraction is { } c ? Math.Max(c, MemoryFraction ?? 0) : MemoryFraction;
}

public enum DockerViewMode { List, Grid }
public enum DockerSortOrder { Updated, Resources, Cpu, Memory }

/// 与 Swift 共用排序口径，未知资源值排在有效值后面。
public static class DockerSorting
{
    public static IEnumerable<DockerContainer> Sorted(this DockerSortOrder sort, IEnumerable<DockerContainer> items, ISet<string>? favorites = null) => items
        .OrderByDescending(item => favorites?.Contains(item.Name) == true)
        .ThenBy(item => item.IsStopped)
        .ThenByDescending(item => sort switch
        {
            DockerSortOrder.Resources => item.ResourceFraction ?? -1,
            DockerSortOrder.Cpu => item.CpuUsagePercent ?? -1,
            DockerSortOrder.Memory => item.MemoryFraction ?? -1,
            _ => item.UpdatedAt ?? item.CreatedAt ?? -1,
        })
        .ThenByDescending(item => item.UpdatedAt ?? item.CreatedAt ?? -1)
        .ThenBy(item => item.Name, StringComparer.Ordinal).ThenBy(item => item.Id, StringComparer.Ordinal);
}

public sealed class DockerLogs
{
    public string Text { get; set; } = "";
    public bool Truncated { get; set; }
    public double? FetchedAt { get; set; }
    public string? Error { get; set; }
    public string? Message { get; set; }
}

public sealed record DockerMetricPoint(double Time, double? Cpu, double? Memory, double? Rx, double? Tx, double? Read, double? Write);

/// 固定样本上限；重建后的容器 ID 不沿用旧容器时间线。
public sealed class DockerHistory
{
    public const int MaxPoints = 600;
    public const double Retention = 6 * 3600;
    readonly Dictionary<Guid, Dictionary<string, List<DockerMetricPoint>>> _hosts = [];
    public IReadOnlyList<DockerMetricPoint> Points(Guid host, string container) => _hosts.GetValueOrDefault(host)?.GetValueOrDefault(container) ?? [];
    public void Record(Guid host, DockerSnapshot snapshot, double? now = null)
    {
        if (snapshot.Error != null) return;
        var cutoff = (now ?? DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0) - Retention;
        var history = _hosts.GetValueOrDefault(host) ?? [];
        var ids = snapshot.Containers.Select(x => x.Id).ToHashSet();
        foreach (var id in history.Keys.ToArray())
        {
            history[id].RemoveAll(x => x.Time < cutoff);
            if (!ids.Contains(id) || history[id].Count == 0) history.Remove(id);
        }
        foreach (var item in snapshot.Containers)
        {
            if (item.State != "running" || item.StatsError != null || item.SampledAt is not { } time || time < cutoff) continue;
            var points = history.GetValueOrDefault(item.Id) ?? [];
            if (points.Count > 0 && points[^1].Time >= time) continue;
            points.Add(new(time, item.CpuUsagePercent, item.MemoryUsed, item.RxRate, item.TxRate, item.ReadRate, item.WriteRate));
            if (points.Count > MaxPoints) points.RemoveRange(0, points.Count - MaxPoints);
            history[item.Id] = points;
        }
        _hosts[host] = history;
    }
}
