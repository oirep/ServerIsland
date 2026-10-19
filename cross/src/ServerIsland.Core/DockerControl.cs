using System.Reflection;
using System.Text.Json;
using System.Text.RegularExpressions;
using ServerIsland.Core.Ssh;

namespace ServerIsland.Core;

public enum DockerControlAction { Start, Stop, Restart }
public sealed class DockerControlResult
{
    public bool Ok { get; set; }
    public string? Error { get; set; }
}

/// 控制脚本与只读采集分开嵌入，必须经过用户确认才调用。
public static class DockerControl
{
    public static string Source
    {
        get
        {
            using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("docker-control.py")
                ?? throw new InvalidOperationException("Missing Docker control resource");
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
    }
    public static string? Script(string container, DockerControlAction action)
    {
        if (!Regex.IsMatch(container, @"\A[a-fA-F0-9]{64}\z") || !Enum.IsDefined(action)) return null;
        return "SI_DOCKER_CONTROL_CONTAINER=" + RemoteScript.ShellQuote(container)
            + " SI_DOCKER_CONTROL_ACTION=" + RemoteScript.ShellQuote(action.ToString().ToLowerInvariant())
            + " python3 - <<'SI_DOCKER_CONTROL_PY'\n" + Source + "\nSI_DOCKER_CONTROL_PY";
    }
}

public sealed partial class MonitorEngine
{
    readonly HashSet<string> _dockerControlRequests = [];

    public async Task<DockerControlResult> ControlDocker(HostConfig host, string container, DockerControlAction action, bool confirmed)
    {
        host = Store.Host(host.Id) ?? host;
        if (!confirmed || !host.Enabled || !host.ShowDocker || DockerControl.Script(container, action) is not { } command)
            return new() { Error = "invalid_control" };
        string key = host.Id + "|" + container;
        if (!_dockerControlRequests.Add(key)) return new() { Error = "control_in_progress" };
        try
        {
            var script = (host.Commands.Preamble.Length == 0 ? "" : host.Commands.Preamble + "\n") + command;
            var result = await Run(host, script, 40);
            if (SshCommon.Classify(result, host) is { } problem)
                return new() { Error = problem.Kind == HealthKind.NeedsLogin ? "needs_login" : "control_unknown" };
            try
            {
                return JsonSerializer.Deserialize<DockerControlResult>(result.Stdout.Split('\n').LastOrDefault(x => x.StartsWith('{')) ?? "", Json.Options)
                    ?? new() { Error = "control_unknown" };
            }
            catch (JsonException) { return new() { Error = "control_unknown" }; }
        }
        finally { _dockerControlRequests.Remove(key); }
    }
}
