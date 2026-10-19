namespace ServerIsland.Core;

public sealed partial class MonitorEngine
{
    readonly Dictionary<Guid, List<RemoteJob>> _localJobs = [];
    readonly Dictionary<string, JobState> _localTaskStates = [];
    bool _localTasksLoaded, _localTaskWatcherStarted;

    /// 与 Mac 一样独立轮询当前用户的本机文件，不受远端暂停/刷新间隔影响。
    void StartLocalTaskMonitoring()
    {
        if (Demo || _localTaskWatcherStarted) return;
        _localTaskWatcherStarted = true;
        RefreshLocalTasks();
        _ = WatchLocalTasks();
    }
    async Task WatchLocalTasks()
    {
        while (true)
        {
            await Task.Delay(TimeSpan.FromSeconds(1));
            RefreshLocalTasks();
        }
    }
    public void RefreshLocalTasks(string? directory = null)
    {
        var records = LocalTaskStore.Read(directory);
        var hosts = Store.Settings.Hosts.Where(h => h.Enabled).ToList();
        var grouped = new Dictionary<Guid, List<RemoteJob>>();
        foreach (var record in records)
        {
            var id = LocalTaskStore.HostID(record, hosts);
            if (!grouped.TryGetValue(id, out var jobs)) grouped[id] = jobs = [];
            jobs.Add(record.Job);
            if (_localTasksLoaded && (!_localTaskStates.TryGetValue(record.Job.Id, out var old)
                || old != record.Job.State) && !record.Job.State.IsActive())
            {
                var host = hosts.FirstOrDefault(h => h.Id == id) ?? LocalTaskStore.LocalHost;
                if (!host.Muted) Emit(new IslandEvent(
                    record.Job.State == JobState.Completed ? EventKind.Finished
                        : record.Job.State == JobState.Failed ? EventKind.Failed : EventKind.Warning,
                    record.Job.Name + " · " + record.Job.State.Label(),
                    record.Job.Message ?? "", host.DisplayName, id));
            }
            _localTaskStates[record.Job.Id] = record.Job.State;
        }
        foreach (var id in _localJobs.Keys.Union(grouped.Keys).ToList())
        {
            var snap = Snapshots.GetValueOrDefault(id) ?? new HostSnapshot();
            snap.Jobs = snap.Jobs.Where(j => !j.Id.StartsWith("local:"))
                .Concat(grouped.GetValueOrDefault(id) ?? [])
                .OrderByDescending(j => j.State.IsActive()).ThenByDescending(j => j.Id.StartsWith("local:")).ToList();
            if (id == HostConfig.LocalTaskID) { snap.Health = HostHealth.Ok; snap.LastUpdate = DateTime.Now; }
            Snapshots[id] = snap;
        }
        _localJobs.Clear();
        foreach (var pair in grouped) _localJobs[pair.Key] = pair.Value;
        _localTasksLoaded = true;
        NotifyChanged();
    }
}
