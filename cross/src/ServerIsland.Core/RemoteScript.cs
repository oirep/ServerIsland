using System.Text;
using System.Text.RegularExpressions;

namespace ServerIsland.Core;

/// 一次轮询只开一个 SSH 通道：把所有要采集的命令拼成一个脚本，
/// 每段输出用 `@@SI:` 标记分隔，并带上退出码，方便定位哪条命令有问题。
/// 这里生成的脚本与 Swift 版（Sources/ServerIsland/Monitor/RemoteScript.swift）逐字对应。
public static class RemoteScript
{
    public const string Marker = "@@SI:";

    public static string ShellQuote(string s) => "'" + s.Replace("'", "'\\''") + "'";

    static string SectionText(string name, string body) =>
        $"printf '{Marker}SEC {name}\\n'\n{{ {body}\n}} 2>&1\nprintf '{Marker}RC %s\\n' \"$?\"";

    public static string Build(HostConfig host)
    {
        var c = host.Commands;
        var lines = new List<string> { $"printf '{Marker}BEGIN\\n'" };
        if (c.Preamble.Trim().Length > 0) lines.Add(c.Preamble);
        void Sec(string name, string body) => lines.Add(SectionText(name, body));

        if (host.ShowCPU) Sec("cpu", "head -n 1 /proc/stat; nproc; cat /proc/loadavg");
        if (host.ShowMemory) Sec("mem", "grep -E '^(MemTotal|MemAvailable):' /proc/meminfo");
        bool listsProcesses = host.Kind == HostKind.Direct || (host.Kind.IsScheduler() && host.SlurmAlsoProcesses);
        if (host.ShowGPU || (listsProcesses && host.WatchJobs))
        {
            // 没有 nvidia-smi 的机器直接跳过，不算错误。
            Sec("gpu", $"if command -v nvidia-smi >/dev/null 2>&1; then {c.Gpu}; else echo '{Marker}NA'; fi");
            if (listsProcesses && host.WatchJobs)
                Sec("gpuapps", $"if command -v nvidia-smi >/dev/null 2>&1; then {c.GpuApps}; else echo '{Marker}NA'; fi");
        }
        if (host.WatchJobs)
        {
            if (host.Kind == HostKind.Slurm)
            {
                Sec("squeue", c.Squeue);
                if (host.SlurmAlsoProcesses)
                {
                    Sec("procs", c.Processes);
                    // 属于 Slurm 作业的进程（环境变量里有 SLURM_JOB_ID）由作业行显示，不再重复列出。
                    Sec("slurmpids", AppDetectors.JobIDFunction + """for p in $(pgrep -u "$(id -un)"); do [ -n "$(si_jobid $p)" ] && echo $p; done; true""");
                }
            }
            else if (host.Kind == HostKind.Pbs)
            {
                Sec("qstat", PbsFunction + $"if command -v qstat >/dev/null 2>&1; then {{ {c.Qstat}\n}} | si_pbs q; else echo 'qstat: command not found'; false; fi");
                if (host.SlurmAlsoProcesses)
                {
                    Sec("procs", c.Processes);
                    // 属于 PBS 作业的进程（环境变量里有 PBS_JOBID）由作业行显示，不再重复列出。
                    Sec("slurmpids", AppDetectors.JobIDFunction + """for p in $(pgrep -u "$(id -un)"); do [ -n "$(si_jobid $p)" ] && echo $p; done; true""");
                }
            }
            else Sec("procs", c.Processes);
        }
        if (host.PathPrefixes.Count > 0 && host.WatchJobs) Sec("workdirs", WorkdirScript(host));
        if (host.DetectApps && host.WatchJobs) Sec("apps", AppDetectors.Script(host));
        if (host.Kind == HostKind.Direct && host.Watched.Count > 0)
        {
            var pids = string.Join(",", host.Watched.Select(w => w.Pid).Where(p => Text.Int(p) != null));
            // 不加 -u：监听的进程不受过滤规则影响。不存在的 PID 会让 ps 返回非 0，属于正常情况。
            if (pids.Length > 0) Sec("watch", $"ps -o pid=,etimes=,pcpu=,rss=,args= -p {pids}; true");
        }
        if (host.ShowDisk) Sec("disk", c.Disk);
        if (host.ReadProgressFiles)
        {
            Sec("progress", $$"""
                for f in {{c.ProgressGlob}}; do
                  [ -f "$f" ] || continue
                  printf '{{Marker}}FILE %s\n' "$f"; head -c 4096 "$f"; echo
                done; true
                """);
        }
        lines.Add($"printf '{Marker}END\\n'");
        return string.Join("\n", lines) + "\n";
    }

    public static string SacctScript(HostConfig host, IEnumerable<string> jobIDs)
    {
        if (host.Kind == HostKind.Pbs)
        {
            // PBS Pro / OpenPBS 用 qstat -x 查已结束的作业；Torque 没有 -x，已结束的作业会以 C 状态保留一段时间。
            var ids = string.Join(" ", jobIDs.Select(SafeSlurmID).Where(x => x != null).Select(x => ShellQuote(PbsID(x!))));
            return Wrap(host, [("sacct", PbsFunction + $"{{ qstat -x -f -t {ids} 2>/dev/null || qstat -f -t {ids} 2>/dev/null; }} | si_pbs a")]);
        }
        var cmd = host.Commands.Sacct.Replace("{jobs}", string.Join(",", jobIDs));
        var s = "";
        if (host.Commands.Preamble.Length > 0) s += host.Commands.Preamble + "\n";
        s += SectionText("sacct", cmd) + "\n";
        return s;
    }

    static string Wrap(HostConfig host, IEnumerable<(string Name, string Body)> sections)
    {
        var sb = new StringBuilder();
        if (host.Commands.Preamble.Length > 0) sb.Append(host.Commands.Preamble).Append('\n');
        foreach (var (name, body) in sections) sb.Append(SectionText(name, body)).Append('\n');
        return sb.ToString();
    }

    /// 只读 log 文件末尾；路径来自远端（scontrol / /proc），在远端 shell 变量里传递，不做本地拼接。
    static string TailVar(string v, int lines) =>
        $"if [ -n \"${v}\" ] && [ -f \"${v}\" ] && [ -r \"${v}\" ]; then printf '{Marker}PATH %s\\n' \"${v}\"; tail -n {lines} \"${v}\" | cut -c1-400; " +
        $"elif [ -n \"${v}\" ]; then printf '{Marker}PATH %s\\n' \"${v}\"; echo '{Marker}UNREADABLE'; fi";

    static readonly Regex SlurmIdRe = new(@"^\d+(_\d+)?$");

    /// Slurm 作业号：123 或数组元素 123_5（只允许数字和下划线，防止注入）。
    public static string? SafeSlurmID(string s) => SlurmIdRe.IsMatch(s) && !s.Contains('\n') ? s : null;

    static string? SafeID(RemoteJob job) =>
        job.Source == JobSource.Slurm ? SafeSlurmID(job.Id) : Text.Int(job.Id)?.ToString();

    /// "123_5" -> "123[5]"（PBS 数组子作业的写法）；普通作业不变。
    public static string PbsID(string id)
    {
        int us = id.IndexOf('_');
        return us < 0 ? id : id[..us] + "[" + id[(us + 1)..] + "]";
    }

    /// 任务详情 + 日志末尾（只在用户打开详情时调用）。
    public static string DetailScript(HostConfig host, RemoteJob job, int logLines = 40)
    {
        if (SafeID(job) is not { } id) return Wrap(host, []);
        if (job.Source == JobSource.Slurm && host.Kind == HostKind.Pbs)
        {
            var q = ShellQuote(PbsID(id));
            var full = $"{{ qstat -x -f {q} 2>/dev/null || qstat -f {q}; }}";
            // Output_Path / Error_Path 形如 主机名:/路径；作业运行时 PBS 常把输出先放在计算节点的 spool 里，结束后才拷回来。
            return Wrap(host, [
                ("qstat", full),
                ("stdout", PbsFunction + $"SI_P=$({full} 2>/dev/null | si_pbsval Output_Path); SI_P=${{SI_P#*:}}\n" + TailVar("SI_P", logLines)),
                ("stderr", PbsFunction + $"SI_O=$({full} 2>/dev/null | si_pbsval Output_Path); SI_O=${{SI_O#*:}}\nSI_E=$({full} 2>/dev/null | si_pbsval Error_Path); SI_E=${{SI_E#*:}}\n[ \"$SI_E\" = \"$SI_O\" ] && SI_E=''\n" + TailVar("SI_E", logLines)),
            ]);
        }
        string scStdOut = $"scontrol show job -o {id} 2>/dev/null | tr ' ' '\\n' | sed -n 's/^StdOut=//p' | head -n 1";
        string scStdErr = $"scontrol show job -o {id} 2>/dev/null | tr ' ' '\\n' | sed -n 's/^StdErr=//p' | head -n 1";
        return job.Source switch
        {
            JobSource.Slurm => Wrap(host, [
                ("scontrol", $"scontrol show job -o {id}"),
                ("sacct", $"sacct -n -X -P -j {id} -o JobID,JobName,Partition,State,ExitCode,Elapsed,Start,End,NodeList,AllocTRES,MaxRSS 2>/dev/null; true"),
                ("stdout", $"SI_P=$({scStdOut})\n" + TailVar("SI_P", logLines)),
                ("stderr", $"SI_O=$({scStdOut})\nSI_E=$({scStdErr})\n[ \"$SI_E\" = \"$SI_O\" ] && SI_E=''\n" + TailVar("SI_E", logLines)),
            ]),
            JobSource.Process => Wrap(host, [
                ("ps", $"ps -o pid=,ppid=,user=,etimes=,pcpu=,pmem=,rss=,stat= -p {id}"),
                ("args", $"tr '\\0' ' ' < /proc/{id}/cmdline; echo"),
                ("cwd", $"readlink /proc/{id}/cwd"),
                ("gpu", $"command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits | grep '^{id},'; true"),
                // 进程的标准输出 / 错误如果被重定向到了文件，就能直接读到日志。
                ("stdout", $"SI_P=$(readlink /proc/{id}/fd/1 2>/dev/null); case \"$SI_P\" in /dev/*|socket:*|pipe:*) echo \"{Marker}NOFILE $SI_P\"; SI_P='';; /*) ;; *) echo \"{Marker}NOFILE $SI_P\"; SI_P='';; esac\n" + TailVar("SI_P", logLines)),
                ("stderr", $"SI_O=$(readlink /proc/{id}/fd/1 2>/dev/null); SI_E=$(readlink /proc/{id}/fd/2 2>/dev/null); case \"$SI_E\" in /dev/*) SI_E='';; /*) ;; *) SI_E='';; esac; [ \"$SI_E\" = \"$SI_O\" ] && SI_E=''\n" + TailVar("SI_E", logLines)),
            ]),
            _ => Wrap(host, []),
        };
    }

    /// 取消前再核对一次（名称一致、属于自己），通过后才执行。
    public static string? CancelScript(HostConfig host, RemoteJob job, double? expectedElapsed, bool force)
    {
        if (SafeID(job) is not { } id) return null;
        const string me = "\"$(id -un)\"";
        switch (job.Source)
        {
            case JobSource.Slurm when host.Kind == HostKind.Pbs:
                var q = ShellQuote(PbsID(id));
                var pname = ShellQuote(job.Name);
                return Wrap(host, [("cancel", PbsFunction + $$"""
                    SI_F=$(qstat -f {{q}} 2>/dev/null)
                    SI_N=$(printf '%s\n' "$SI_F" | si_pbsval Job_Name)
                    SI_W=$(printf '%s\n' "$SI_F" | si_pbsval Job_Owner); SI_W=${SI_W%%@*}
                    SI_S=$(printf '%s\n' "$SI_F" | si_pbsval job_state)
                    if [ -z "$SI_F" ] || [ "$SI_N" != {{pname}} ] || [ "$SI_W" != {{me}} ]; then echo '{{Marker}}ABORT 作业已不在队列中，或不属于你'; exit 3; fi
                    case "$SI_S" in F|X|C) echo '{{Marker}}ABORT 作业已经结束'; exit 3;; esac
                    qdel {{q}} && echo '{{Marker}}DONE'
                    """)]);
            case JobSource.Slurm:
                var name = ShellQuote(job.Name);
                return Wrap(host, [("cancel", $"""
                    SI_N=$(squeue -h -j {id} -u {me} -o '%j' 2>/dev/null | head -n 1)
                    if [ "$SI_N" != {name} ]; then echo '{Marker}ABORT 作业已不在队列中，或不属于你'; exit 3; fi
                    scancel {id} && echo '{Marker}DONE'
                    """)]);
            case JobSource.Process:
                const int tol = 20;
                var check = expectedElapsed is { } e
                    ? $"SI_T=$(ps -o etimes= -p {id} | tr -d ' '); SI_D=$(( SI_T - {(long)e} )); [ ${{SI_D#-}} -le {tol} ] || {{ echo '{Marker}ABORT 进程已变化（PID 可能被复用）'; exit 3; }}"
                    : "";
                return Wrap(host, [("cancel", $"""
                    SI_U=$(ps -o user= -p {id} 2>/dev/null | tr -d ' ')
                    if [ -z "$SI_U" ]; then echo '{Marker}ABORT 进程已经结束'; exit 3; fi
                    if [ "$SI_U" != {me} ]; then echo '{Marker}ABORT 进程不属于你'; exit 3; fi
                    {check}
                    kill -{(force ? "KILL" : "TERM")} {id} && echo '{Marker}DONE'
                    """)]);
            default:
                return null;
        }
    }

    /// 最近 24 小时的作业（需要集群开启 accounting；不支持时返回非 0）。
    public static string HistoryScript(HostConfig host) =>
        Wrap(host, [("history", """sacct -n -X -P -S now-24hours -u "$(id -un)" -o JobID,JobName,State,Elapsed,End,ExitCode""")]);

    /// 高负载进程（给用户挑选要监听的 PID）。
    public static string TopProcessesScript(HostConfig host) => Wrap(host, [
        ("procs", """ps -u "$(id -un)" -o pid=,etimes=,pcpu=,rss=,args= --sort=-pcpu | head -n 40"""),
        ("gpuapps", $"command -v nvidia-smi >/dev/null 2>&1 && {host.Commands.GpuApps}; true"),
    ]);

    /// 用于"自动检测类型"。
    public const string DetectScript = """
        for c in squeue sbatch sinfo qstat qsub qselect nvidia-smi; do
          if command -v "$c" >/dev/null 2>&1; then echo "$c=yes"; else echo "$c=no"; fi
        done
        if pgrep -x slurmd >/dev/null 2>&1; then echo "slurmd=yes"; else echo "slurmd=no"; fi
        uname -sr
        """;

    /// 每个任务的工作目录（目录过滤用）：作业用调度系统记录的工作目录，进程用当前目录。输出 `id|目录`，另有一行 `@@SI:HOME 家目录`。
    public static string WorkdirScript(HostConfig host)
    {
        const string me = "\"$(id -un)\"";
        var s = $"printf '{Marker}HOME %s\\n' \"$HOME\"\n";
        if (host.Kind == HostKind.Slurm) s += $"squeue -u {me} -h -o '%i|%Z' 2>/dev/null\n";
        else if (host.Kind == HostKind.Pbs) s += PbsFunction + $"{{ {host.Commands.Qstat}\n}} 2>/dev/null | si_pbs d\n";
        if (host.Kind == HostKind.Direct || host.SlurmAlsoProcesses)
            s += $"for p in $(pgrep -u {me}); do d=$(readlink /proc/$p/cwd 2>/dev/null) && printf '%s|%s\\n' \"$p\" \"$d\"; done\n";
        return s + "true";
    }

    /// PBS（PBS Pro / OpenPBS / Torque）：把 `qstat -f` 的全文转换成和 squeue / sacct 一样的行（说明见 Swift 版 RemoteScript.pbsFunction）。
    /// 文本和 Swift 版逐字一致。
    public const string PbsFunction = """
        si_pbs() { awk -v mode="$1" '
        function clear() { id = ""; k = ""; delete v }
        function out(   jid, arr, task, st, ex, S, name, n, r, h, nh, parts, i, x, seen, wd) {
          if (id == "") return
          jid = id; sub(/\..*$/, "", jid)
          if (jid ~ /\[\]$/) { clear(); return }
          arr = jid; task = "N/A"
          if (match(jid, /\[[0-9]+\]$/)) { task = substr(jid, RSTART + 1, RLENGTH - 2); arr = substr(jid, 1, RSTART - 1); jid = arr "_" task }
          st = v["job_state"]; ex = v["Exit_status"]; if (ex == "") ex = v["exit_status"]
          if (st == "R" || st == "B") S = "RUNNING"
          else if (st == "E") S = "COMPLETING"
          else if (st == "S" || st == "U") S = "SUSPENDED"
          else if (st == "F" || st == "X" || st == "C") {
            if (ex == "") S = (v["stime"] == "" && v["start_time"] == "" && v["resources_used.walltime"] == "") ? "CANCELLED" : "COMPLETED"
            else if (ex + 0 == 0) S = "COMPLETED"
            else if (ex + 0 == -29 || ex + 0 == -11) S = "TIMEOUT"
            else if (ex + 0 >= 256) S = "CANCELLED"
            else S = "FAILED"
          } else S = "PENDING"
          name = v["Job_Name"]; gsub(/\|/, "/", name)
          n = v["Resource_List.nodect"]; if (n == "") { n = v["Resource_List.nodes"]; sub(/[^0-9].*$/, "", n) }; if (n == "") n = 1
          if (S == "PENDING") {
            r = v["comment"]; gsub(/\|/, "/", r)
            if (st == "H") r = "JobHeldUser" (r == "" ? "" : ": " r)
            else if (st == "W") r = "BeginTime"
            else if (r == "") r = "Priority"
            r = "(" r ")"
          } else {
            h = v["exec_host"]; r = ""; nh = split(h, parts, "+")
            for (i = 1; i <= nh; i++) { x = parts[i]; sub(/\/.*$/, "", x); if (x != "" && !(x in seen)) { seen[x] = 1; r = r (r == "" ? "" : ",") x } }
          }
          wd = v["Variable_List"]
          if (match(wd, /PBS_O_WORKDIR=[^,]*/)) wd = substr(wd, RSTART + 14, RLENGTH - 14); else wd = ""
          if (mode == "q") { if (st != "F" && st != "X" && st != "C") print jid "|" name "|" S "|" v["resources_used.walltime"] "|" v["Resource_List.walltime"] "|" n "|" r "|" v["queue"] "|" arr "|" task }
          else if (mode == "a") print jid "|" name "|" S "|" v["resources_used.walltime"] "|" (ex == "" ? "" : ex ":0")
          else if (mode == "w") { if (S == "RUNNING" && wd != "") print jid "|" wd }
          else if (mode == "d") { if (wd != "") print jid "|" wd }
          clear()
        }
        /^Job Id: / { out(); id = substr($0, 9); gsub(/[ \t\r]/, "", id); next }
        /^\t/ { if (k != "") { t = $0; sub(/^\t+/, "", t); sub(/\r$/, "", t); v[k] = v[k] t }; next }
        /^ +[A-Za-z_][A-Za-z0-9_.]* = / { t = $0; sub(/^ +/, "", t); sub(/\r$/, "", t); i = index(t, " = "); k = substr(t, 1, i - 1); v[k] = substr(t, i + 3); next }
        { k = "" }
        END { out() }'; }
        si_pbsval() { awk -v key="$1" '/^\t/ { if (on) { t = $0; sub(/^\t+/, "", t); val = val t }; next } { on = 0 } $0 ~ ("^ +" key " = ") { on = 1; val = substr($0, index($0, " = ") + 3) } END { print val }'; }

        """;

    public sealed class Section
    {
        public List<string> Lines = [];
        public int? ExitCode;
        public bool NotAvailable => Lines.Count > 0 && Lines[0] == Marker + "NA";
        public string Text => string.Join("\n", Lines);
    }

    public sealed class Parsed
    {
        public Dictionary<string, Section> Sections = [];
        public bool SawBegin;
        public bool SawEnd;
        public Section? Get(string name) => Sections.GetValueOrDefault(name);
    }

    public static Parsed Parse(string output)
    {
        var parsed = new Parsed();
        string? current = null;
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.EndsWith('\r') ? raw[..^1] : raw;
            if (line.StartsWith(Marker, StringComparison.Ordinal))
            {
                var rest = line[Marker.Length..];
                if (rest == "BEGIN") { parsed.SawBegin = true; continue; }
                if (rest == "END") { parsed.SawEnd = true; current = null; continue; }
                if (rest.StartsWith("SEC ", StringComparison.Ordinal))
                {
                    var name = rest[4..];
                    parsed.Sections[name] = new Section();
                    current = name;
                    continue;
                }
                if (rest.StartsWith("RC ", StringComparison.Ordinal) && current != null)
                {
                    parsed.Sections[current].ExitCode = Text.Int(rest[3..]);
                    current = null;
                    continue;
                }
            }
            // BEGIN 之前的内容（如 .bashrc 的输出）直接忽略。
            if (current != null) parsed.Sections[current].Lines.Add(line);
        }
        return parsed;
    }
}
