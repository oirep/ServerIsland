using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

public enum JobState { Running, Pending, Completing, Completed, Failed, Cancelled, Timeout, Other }

public static class JobStates
{
    /// 仍在队列 / 运行中。
    public static bool IsActive(this JobState s) => s is JobState.Running or JobState.Pending or JobState.Completing;

    public static string Label(this JobState s) => s switch
    {
        JobState.Running => L("运行中", "Running"),
        JobState.Pending => L("排队中", "Pending"),
        JobState.Completing => L("收尾中", "Completing"),
        JobState.Completed => L("已完成", "Completed"),
        JobState.Failed => L("失败", "Failed"),
        JobState.Cancelled => L("已取消", "Cancelled"),
        JobState.Timeout => L("超时", "Timed out"),
        _ => L("未知", "Unknown"),
    };

    /// 和 Swift 的 rawValue 一致（历史记录里用到）。
    public static string Raw(this JobState s) => s.ToString().ToLowerInvariant();

    public static JobState? FromRaw(string raw) => raw switch
    {
        "running" => JobState.Running,
        "pending" => JobState.Pending,
        "completing" => JobState.Completing,
        "completed" => JobState.Completed,
        "failed" => JobState.Failed,
        "cancelled" => JobState.Cancelled,
        "timeout" => JobState.Timeout,
        "other" => JobState.Other,
        _ => null,
    };

    /// 把 Slurm 的状态字符串（如 RUNNING / CANCELLED by 123 / OUT_OF_MEMORY）映射过来。
    public static JobState FromSlurm(string raw)
    {
        var s = raw.ToUpperInvariant();
        bool P(string p) => s.StartsWith(p, StringComparison.Ordinal);
        if (P("RUNNING") || s == "R") return JobState.Running;
        if (P("PENDING") || s == "PD" || P("CONFIGURING") || P("REQUEUED") || P("RESIZING")) return JobState.Pending;
        if (P("COMPLETING") || s == "CG" || P("STAGE_OUT")) return JobState.Completing;
        if (P("COMPLETED") || s == "CD") return JobState.Completed;
        if (P("CANCELLED") || s == "CA") return JobState.Cancelled;
        if (P("TIMEOUT") || s == "TO" || P("DEADLINE")) return JobState.Timeout;
        if (P("FAILED") || P("NODE_FAIL") || P("OUT_OF_MEMORY") || P("BOOT_FAIL") || s == "F" || s == "OOM" || s == "NF") return JobState.Failed;
        if (P("SUSPENDED") || P("PREEMPTED") || P("STOPPED")) return JobState.Pending;
        return JobState.Other;
    }
}

public enum JobSource { Slurm, Process, ProgressFile }

/// 一个"任务"：Slurm 作业、直连服务器上的进程，或进度文件里的条目。
public sealed class RemoteJob
{
    public string Id = "";
    public string Name = "";
    public JobState State;
    public string RawState = "";
    public JobSource Source;
    /// 采样时刻的已运行时长（秒）。
    public double? Elapsed;
    /// 时间上限（秒），Slurm 的 TimeLimit。
    public double? Limit;
    /// 节点列表 / 排队原因 / 分区等补充信息。
    public string Detail = "";
    /// 0...1，来自进度文件。
    public double? Progress;
    public string? Message;
    public double? CpuPercent;
    public double? MemoryBytes;
    public double? GpuMemoryMB;
    /// 用户手动监听的进程。
    public bool Watched;
    /// Slurm 数组作业：主编号（如 123）与元素序号或范围（如 5 / [7-99%10]）。
    public string? ArrayJobID;
    public string? ArrayTask;
    /// 合并后的整个数组（只有分组行有）。
    public ArrayInfo? Array;
    /// 识别到的计算软件进度。
    public AppProgress? App;
    /// 预计剩余时间（由真实速度算出时才有）。
    public double? Eta;
    /// 排队原因（原始值，不含括号）。
    public string? Reason;
    /// 工作目录（作业：调度系统记录的；进程：当前目录）。写进历史记录，之后可以直接打开。
    public string? Workdir;

    public RemoteJob() { }

    public RemoteJob(string id, string name, JobState state, JobSource source)
    {
        Id = id; Name = name; State = state; Source = source;
    }

    /// 用于进度条的比例：数组用"已结束 / 总数"，其次真实进度，再其次"已运行 / 时间上限"。
    public double? Fraction
    {
        get
        {
            if (Array is { Total: > 0 } a) return (double)(a.Done + a.Failed) / a.Total;
            if (Progress is { } p) return Math.Clamp(p, 0, 1);
            if (Elapsed is { } e && Limit is { } l && l > 0) return Math.Clamp(e / l, 0, 1);
            return null;
        }
    }

    public bool HasRealProgress => Progress != null || Array != null;

    /// 计入"运行中 / 排队中"的数量（数组按元素算）。
    public int RunningUnits => Array is { } a ? a.Running.Count : State is JobState.Running or JobState.Completing ? 1 : 0;
    public int PendingUnits => Array is { } a ? a.Pending : State == JobState.Pending ? 1 : 0;

    public RemoteJob Clone()
    {
        var c = (RemoteJob)MemberwiseClone();
        c.Array = Array?.Clone();
        c.App = App?.Clone();
        return c;
    }
}

/// 一个 Slurm 数组作业的汇总。
public sealed class ArrayInfo
{
    public string BaseID = "";
    public List<RemoteJob> Running = [];
    public int Pending;
    /// 已结束的元素（成功 / 失败），来自 sacct 或运行期间的观察。
    public int Done;
    public int Failed;
    /// 元素总数（观察到的最大值）。
    public int Total;
    /// done / failed 是否来自 sacct（否则是运行期间观察到的，可能偏少）。
    public bool Accurate;

    public ArrayInfo Clone()
    {
        var c = (ArrayInfo)MemberwiseClone();
        c.Running = [.. Running];
        return c;
    }
}

public sealed class GPUStat
{
    public int Index;
    public string Name = "";
    public double Utilization;   // 0...100
    public double MemoryUsedMB;
    public double MemoryTotalMB;
    public double? Temperature;

    public double MemoryFraction => MemoryTotalMB > 0 ? MemoryUsedMB / MemoryTotalMB : 0;

    /// "NVIDIA GeForce RTX 5090 D v2" -> "RTX 5090 D v2"
    public static string ShortName(string name) => name.Replace("NVIDIA ", "").Replace("GeForce ", "");
}

public sealed class DiskStat
{
    public string Mount = "";
    public double UsedKB;
    public double TotalKB;
    public double Fraction => TotalKB > 0 ? UsedKB / TotalKB : 0;
}

public sealed class HostMetrics
{
    public double? CpuPercent;
    public double? Load1;
    public int? Cores;
    public double? MemoryUsed;
    public double? MemoryTotal;

    public double? MemoryFraction => MemoryUsed is { } u && MemoryTotal is { } t && t > 0 ? u / t : null;
}

public enum HealthKind { Unknown, Ok, NeedsLogin, Error }

public sealed record HostHealth(HealthKind Kind, string Message = "")
{
    public static readonly HostHealth Unknown = new(HealthKind.Unknown);
    public static readonly HostHealth Ok = new(HealthKind.Ok);
    public static HostHealth NeedsLogin(string m) => new(HealthKind.NeedsLogin, m);
    public static HostHealth Error(string m) => new(HealthKind.Error, m);

    public bool IsProblem => Kind is HealthKind.NeedsLogin or HealthKind.Error;
    public override string ToString() => Message.Length > 0 ? $"{Kind}({Message})" : Kind.ToString();
}

public sealed class HostSnapshot
{
    public HostHealth Health = HostHealth.Unknown;
    public HostMetrics Metrics = new();
    public List<GPUStat> Gpus = [];
    public List<DiskStat> Disks = [];
    public List<RemoteJob> Jobs = [];
    public DateTime? LastUpdate;
    public double? Latency;
    /// 某个命令执行失败等非致命问题，显示在卡片里，方便用户去设置里调整。
    public List<string> Warnings = [];
    public bool IsRefreshing;

    public int RunningCount => Jobs.Sum(j => j.RunningUnits);
    public int PendingCount => Jobs.Sum(j => j.PendingUnits);

    public HostSnapshot Copy()
    {
        var c = (HostSnapshot)MemberwiseClone();
        c.Jobs = [.. Jobs];
        return c;
    }
}

public enum EventKind { Finished, Failed, Started, Info, Warning }

/// 刘海弹出提示。
public sealed class IslandEvent(EventKind kind, string title, string subtitle, string hostName, Guid? hostID = null, string? jobID = null)
{
    public Guid Id { get; } = Guid.NewGuid();
    public EventKind Kind { get; } = kind;
    public Guid? HostID { get; } = hostID;
    /// 任务提醒对应的任务号（数组是主编号）；服务器级提醒（磁盘等）为 null。用于按关注范围和种类过滤。
    public string? JobID { get; } = jobID;
    public string Title { get; } = title;
    public string Subtitle { get; } = subtitle;
    public string HostName { get; } = hostName;
    public DateTime Date { get; } = DateTime.Now;
}

/// 已结束任务的记录（用于"最近 24 小时"）。
public sealed class HistoryEntry
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    /// JobState 的 raw 值或 Slurm 原始状态
    public string State { get; set; } = "";
    public double? Elapsed { get; set; }
    public DateTime EndedAt { get; set; }
    public string? ExitCode { get; set; }
    public string? Note { get; set; }
    /// 工作目录（历史页上可以直接在终端打开）。
    public string? Dir { get; set; }

    /// ServerIsland 没在运行时结束的任务，不知道结果（State 写这个值）。
    public const string EndedUnknown = "ENDED";

    public JobState JobState => JobStates.FromRaw(State) ?? JobStates.FromSlurm(State);
    public string StateLabel => State == EndedUnknown ? Lang.L("已结束", "Ended") : JobState == JobState.Other ? State : JobState.Label();
}
