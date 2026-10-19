using System.Text.Json;
using ServerIsland.Core.Ssh;

namespace ServerIsland.Core;

public sealed record DockerLiveResult(string? Message = null, bool Retry = true);

public sealed partial class MonitorEngine
{
    readonly HashSet<string> _dockerLiveRequests = [];

    /// 详情只采所选容器，与全局分钟级轮询分离，取消后不再提交迟到响应。
    public async Task MonitorDockerDetail(HostConfig host, string container, Action<DockerLiveResult> onUpdate, CancellationToken cancellation = default)
    {
        int failures = 0;
        while (!cancellation.IsCancellationRequested)
        {
            var started = DateTime.UtcNow;
            var result = await RefreshDockerDetail(host, container, cancellation);
            if (cancellation.IsCancellationRequested) return;
            onUpdate(result);
            failures = result.Message == null ? 0 : failures + 1;
            if (!result.Retry) return;
            double delay = failures > 0 ? Math.Min(15, Math.Pow(2, Math.Min(failures, 4)))
                : Math.Max(0.05, 1 - (DateTime.UtcNow - started).TotalSeconds);
            try { await Task.Delay(TimeSpan.FromSeconds(delay), cancellation); }
            catch (OperationCanceledException) { return; }
        }
    }

    public async Task<DockerLiveResult> RefreshDockerDetail(HostConfig host, string container, CancellationToken cancellation = default)
    {
        host = Store.Host(host.Id) ?? host;
        if (!host.Enabled || !host.ShowDocker || DockerMonitor.DetailScript(container) is not { } command)
            return new(DockerSnapshot.ErrorText("invalid_container"), false);
        string key = host.Id + "|" + container;
        if (!_dockerLiveRequests.Add(key)) return new();
        try
        {
            var script = (host.Commands.Preamble.Length == 0 ? "" : host.Commands.Preamble + "\n") + command;
            var result = await Run(host, script, 12);
            if (cancellation.IsCancellationRequested) return new(null, false);
            if (Store.Host(host.Id) is not { Enabled: true, ShowDocker: true }) return new(DockerSnapshot.ErrorText("invalid_container"), false);
            if (SshCommon.Classify(result, host) is { } problem) return new(problem.Message, problem.Kind != HealthKind.NeedsLogin);
            var fresh = DockerSnapshot.Parse(result.Stdout.Split('\n'), Snapshots.GetValueOrDefault(host.Id)?.Docker);
            string? error = fresh.Error ?? fresh.Containers.FirstOrDefault()?.StatsError;
            if (error != null)
            {
                bool terminal = new[] { "invalid_container", "container_missing", "unsupported_endpoint", "python_missing", "permission_denied", "socket_missing" }.Contains(error);
                return new(DockerSnapshot.ErrorText(error), !terminal);
            }
            ApplyDockerDetail(fresh, host.Id);
            return new();
        }
        finally { _dockerLiveRequests.Remove(key); }
    }

    /// 部分结果只合并单个容器，不覆盖全局资源或其它容器。
    public void ApplyDockerDetail(DockerSnapshot incoming, Guid host)
    {
        if (incoming.Error != null || incoming.Containers.Count != 1) return;
        var snapshot = Snapshots.GetValueOrDefault(host)?.Copy() ?? new HostSnapshot();
        var oldDocker = snapshot.Docker ?? new DockerSnapshot();
        var docker = new DockerSnapshot { Containers = [.. oldDocker.Containers], Total = oldDocker.Total, Running = oldDocker.Running,
            Truncated = oldDocker.Truncated, SampleLimited = oldDocker.SampleLimited, Socket = incoming.Socket ?? oldDocker.Socket,
            Version = incoming.Version ?? oldDocker.Version };
        var item = incoming.Containers[0];
        int index = docker.Containers.FindIndex(x => x.Id == item.Id);
        if (index >= 0)
        {
            var old = docker.Containers[index];
            if (old.SampledAt is { } before && item.SampledAt is { } after && before > after) return;
            docker.Running = Math.Max(0, docker.Running + (item.State == "running" ? 1 : 0) - (old.State == "running" ? 1 : 0));
            docker.Containers[index] = item;
        }
        else
        {
            docker.Containers.Add(item);
            docker.Total = Math.Max(docker.Total + 1, docker.Containers.Count);
            if (item.State == "running") docker.Running++;
        }
        DockerHistory.Record(host, docker);
        snapshot.Docker = docker;
        Snapshots[host] = snapshot;
        NotifyChanged();
    }

    /// 只在详情日志页按需读取，GET 日志尾部不修改服务器，也不把日志写入本地文件。
    public async Task<DockerLogs> FetchDockerLogs(HostConfig host, string container, int tail = 200)
    {
        host = Store.Host(host.Id) ?? host;
        if (!host.Enabled || !host.ShowDocker || DockerMonitor.LogScript(container, tail) is not { } command)
            return new() { Error = "invalid_container" };
        var script = (host.Commands.Preamble.Length == 0 ? "" : host.Commands.Preamble + "\n") + command;
        var result = await Run(host, script, 15);
        if (SshCommon.Classify(result, host) is { } problem) return new() { Error = "ssh", Message = problem.Message };
        try
        {
            return JsonSerializer.Deserialize<DockerLogs>(result.Stdout.Split('\n').LastOrDefault(x => x.StartsWith('{')) ?? "", Json.Options)
                ?? new() { Error = "invalid_response" };
        }
        catch (JsonException) { return new() { Error = "invalid_response" }; }
    }
}
