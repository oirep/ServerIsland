using System.Globalization;
using System.Text.RegularExpressions;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

public enum AppKind { Nep, Gnep, Gpumd, Vasp, Lammps, Custom }

/// VASP 的计算类型。
public enum VaspMode { Md, Relax, Scf, Neb }

/// 计算软件的进度（NEP / GPUMD 参考 GPUMDkit Web Console 的判断逻辑；另有 VASP、LAMMPS 和用户自定义规则）。
/// 原则：任何一处和预期不一致（文件缺失、格式对不上、数字矛盾）就当作没识别到，不显示进度。
public sealed class AppProgress
{
    public sealed record Value(string Label, double V);
    public sealed record Neighbor(int RadialActual, int RadialMax, int AngularActual, int AngularMax);

    public AppKind Kind;
    public string Dir = "";
    public double? Current;
    public double? Total;
    /// nep.in / run.in 里是否写了目标（没写时用默认值，进度仅供参考）。
    public bool HasTarget = true;
    public List<Value> Losses = [];
    public Neighbor? Neigh;
    /// 输出文件的最后修改时间（用来判断是否卡住）。
    public DateTime? UpdatedAt;
    /// 由引擎根据两次采样算出：每秒推进多少代 / 步。
    public double? Rate;
    /// 正常结束标记（VASP 的 OUTCAR 计时段、LAMMPS 的 Total wall time、自定义规则的结束文字）。null：没有结束标记。
    public bool? EndMarker;
    public VaspMode? Vasp;
    /// NEB：正向能垒（最高点 − 初态，eV；没有初态 OUTCAR 时为 null）、中间像点里最大的 VTST 力、中间像点数。
    public double? NebBarrier;
    public double? NebForce;
    public int? NebImages;
    public string CustomName = "";
    public string CustomUnit = "";

    public AppProgress() { }
    public AppProgress(AppKind kind, string dir) { Kind = kind; Dir = dir; }

    public AppProgress Clone()
    {
        var c = (AppProgress)MemberwiseClone();
        c.Losses = [.. Losses];
        return c;
    }

    public string Title => Kind switch
    {
        AppKind.Nep => L("NEP 训练", "NEP training"),
        AppKind.Gnep => L("GNEP 训练", "GNEP training"),
        AppKind.Gpumd => L("GPUMD 模拟", "GPUMD MD"),
        AppKind.Vasp => (Vasp ?? VaspMode.Scf) switch
        {
            VaspMode.Md => "VASP MD",
            VaspMode.Relax => L("VASP 结构优化", "VASP relaxation"),
            VaspMode.Neb => "VASP NEB",
            _ => L("VASP 单点", "VASP SCF"),
        },
        AppKind.Lammps => "LAMMPS MD",
        _ => CustomName,
    };

    public string Unit => Kind switch
    {
        AppKind.Nep => L("代", "gen"),
        AppKind.Gnep => "epoch",
        AppKind.Gpumd or AppKind.Lammps => L("步", "steps"),
        AppKind.Vasp => (Vasp ?? VaspMode.Scf) switch
        {
            VaspMode.Md => L("步", "steps"),
            VaspMode.Relax or VaspMode.Neb => L("离子步", "ionic steps"),
            _ => L("电子步", "electronic steps"),
        },
        _ => CustomUnit,
    };

    public double? Fraction => Current is { } c && Total is { } t && t > 0 ? Math.Clamp(c / t, 0, 1) : null;

    public bool Finished
    {
        get
        {
            if (EndMarker is { } m) return m;
            if (Current is not { } c || Total is not { } t || !HasTarget) return false;
            return c >= t;
        }
    }

    /// 任务结束时能否判断成功 / 失败：有目标值或有结束标记。
    public bool CanJudge => EndMarker != null || HasTarget;

    public double? Eta => Current is { } c && Total is { } t && Rate is { } r && r > 0 && c < t ? (t - c) / r : null;

    /// 一行摘要，显示在任务行里。
    public string Summary
    {
        get
        {
            var parts = new List<string>();
            if (Current is { } c)
            {
                var cur = Compact(c);
                var u = Unit.Length == 0 ? "" : " " + Unit;
                parts.Add(Total is { } t ? $"{cur}/{Compact(t)}{u}" : $"{cur}{u}");
            }
            switch (Kind)
            {
                case AppKind.Nep or AppKind.Gnep:
                    if (Losses.Count > 0) parts.Add($"{Losses[0].Label} {Sci(Losses[0].V)}");
                    break;
                case AppKind.Gpumd or AppKind.Lammps:
                    if (Rate is { } r) parts.Add(Compact(r) + L(" 步/秒", " steps/s"));
                    break;
                case AppKind.Vasp when Vasp == VaspMode.Neb:
                    if (NebBarrier is { } b) parts.Add(L("能垒 ", "barrier ") + Text.Fmt(b, "0.000") + " eV");
                    if (NebForce is { } f) parts.Add(L("最大力 ", "max force ") + Sci(f));
                    break;
            }
            return string.Join(" · ", parts);
        }
    }

    public static string Compact(double v)
    {
        var a = Math.Abs(v);
        if (a >= 1e9) return Text.Fmt(v / 1e9, "0.00") + "G";
        if (a >= 1e6) return Text.Fmt(v / 1e6, "0.00") + "M";
        if (a >= 100 || v == Math.Round(v)) return Math.Round(v, MidpointRounding.AwayFromZero).ToString("#,0", CultureInfo.InvariantCulture);
        return Text.Fmt(v, "0.00");
    }

    public static string Sci(double v)
    {
        var a = Math.Abs(v);
        if (a != 0 && (a < 1e-3 || a >= 1e4)) return v.ToString("0.00e+00", CultureInfo.InvariantCulture);
        return Text.Fmt(v, "0.0000");
    }
}

public sealed class RuleTestResult
{
    public bool Ok;
    public string Headline = "";
    /// 补充说明，以及没匹配上时文件的最后几行。
    public List<string> Notes = [];
    public List<string> Lines = [];
}

/// 远端脚本与 Swift 版 AppDetectors.swift 逐字对应。
public static class AppDetectors
{
    const string Marker = RemoteScript.Marker;
    static string Q(string s) => RemoteScript.ShellQuote(s);

    /// shell 函数：si_pick 取最新的匹配文件；si_jobid 从 /proc/<pid>/environ 读出所属 Slurm 作业号（数组元素为 主编号_序号）。
    public const string JobIDFunction = """
        si_pick() { (cd "$1" 2>/dev/null && ls -td -- $2 2>/dev/null | head -n 1); }
        si_jobid() { tr '\0' '\n' < /proc/$1/environ 2>/dev/null | awk -F= '$1=="SLURM_ARRAY_JOB_ID"{a=$2} $1=="SLURM_ARRAY_TASK_ID"{t=$2} $1=="SLURM_JOB_ID"{j=$2} $1=="PBS_JOBID"{b=$2} END{if(a!=""&&t!="")print a"_"t; else if(j!="")print j; else if(b!=""){sub(/\..*$/,"",b); sub(/\[/,"_",b); sub(/\]/,"",b); print b}}'; }

        """;

    /// 远端脚本：收集"任务 ID | 工作目录"，再逐个目录识别软件。
    public static string Script(HostConfig host)
    {
        const string me = "\"$(id -un)\"";
        var names = host.AppProcessNames.Replace("'", "");
        // 候选进程：名字匹配，或者正在用 GPU，或者 CPU ≥ 50%。真正判断是哪种软件靠工作目录里的文件。
        bool showLocal = host.Kind == HostKind.Direct || (host.Kind.IsScheduler() && host.SlurmAlsoProcesses);
        var slurmPids = host.Kind.IsScheduler() ? $"for q in $(pgrep -u {me}); do [ -n \"$(si_jobid $q)\" ] && echo $q; done" : "";
        var localElse = showLocal ? "else printf '%s|%s\\n' \"$p\" \"$d\";" : "";
        var candidates = $$"""
              for p in $( { pgrep -u {{me}} -x '{{names}}'
                            command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-compute-apps=pid --format=csv,noheader
                            ps -u {{me}} -o pid=,pcpu= | awk '$2 >= 50 {print $1}'
                            {{slurmPids}}
                          } 2>/dev/null | sort -un | head -n 60 ); do
                d=$(readlink /proc/$p/cwd 2>/dev/null) || continue
                # 属于 Slurm 作业的进程映射回作业号（单机 Slurm 能拿到作业真正运行的目录）
                j=$(si_jobid $p)
                if [ -n "$j" ]; then printf '%s|%s\n' "$j" "$d"; {{localElse}} fi
              done
            """;
        var slurm = host.Kind switch
        {
            HostKind.Slurm => $"squeue -u {me} -h -t R -o '%i|%Z' 2>/dev/null | head -n 40",
            HostKind.Pbs => $"{{ {host.Commands.Qstat}\n}} 2>/dev/null | si_pbs w | head -n 40",
            _ => "",
        };
        var pbs = host.Kind == HostKind.Pbs ? RemoteScript.PbsFunction : "";
        return $"""
            {JobIDFunction}{pbs}
            {"{"} {slurm}
            {candidates}
            {"}"} | awk -F'|' '!seen[$2]++' | while IFS='|' read -r id d; do
            {DirBody(ProgressRule.Active.Where(r => r.IsUsable).ToList())}
            done; true
            """;
    }

    /// 任务结束时再读一次最终状态（只读这一个目录），避免"最后一次采样还没到目标"被误判为提前结束。
    public static string FinalStateScript(string id, string dir) =>
        DirectoryScript(id, dir, ProgressRule.Active.Where(r => r.IsUsable).ToList(), builtin: true);

    /// 只对一个目录跑识别。设置页"测试规则"用 `rules: [规则], builtin: false`。
    public static string DirectoryScript(string id, string dir, IReadOnlyList<ProgressRule> rules, bool builtin) => $"""
        {JobIDFunction}
        id={Q(id)}; d={Q(dir)}
        case "$d" in "~"/*) d="$HOME/${"{"}d#\~/{"}"}";; esac
        for _ in 1; do
        {DirBody(rules, builtin)}
        done; true

        """;

    /// 对单个目录（变量 $id、$d）识别软件并输出 key=value。自定义规则排在内置识别前面。
    static string DirBody(IReadOnlyList<ProgressRule> rules, bool builtin = true)
    {
        var branches = rules.Select(CustomBranch).ToList();
        if (builtin) branches.Add(BuiltinBranches);
        if (branches.Count == 0) return "  :";
        return "  [ -n \"$d\" ] && [ -d \"$d\" ] || continue\n  if " + string.Join("\n  elif ", branches) + "\n  fi";
    }

    /// 一条自定义规则：条件 + 输出。文件名已经过 IsSafeFileName 检查，其余字符串一律 shellQuote。
    static string CustomBranch(ProgressRule r)
    {
        var body = $"f=\"$d/$(si_pick \"$d\" '{r.File}')\"\n    printf '{Marker}DIR %s|%s\\n' \"$id\" \"$d\"; echo kind=custom; echo rule={r.IdString}";
        if (r.Match == RuleMatch.Keyword)
            body += $"\n    grep -aiF -- {Q(r.Pattern)} \"$f\" | tail -n 5 | cut -c1-300 | sed 's/^/tail=/'";
        else
            body += "\n    tail -n 40 \"$f\" | cut -c1-300 | sed 's/^/tail=/'";
        if (r.TotalFile.Length > 0)
            body += $"\n    tf=$(si_pick \"$d\" '{r.TotalFile}'); [ -n \"$tf\" ] && grep -aiF -m 1 -- {Q(r.TotalKeyword)} \"$d/$tf\" | cut -c1-300 | sed 's/^/totalline=/'";
        if (r.DoneMarker.Length > 0)
            body += $"\n    if tail -n 50 \"$f\" | grep -qaF -- {Q(r.DoneMarker)}; then echo done=1; else echo done=0; fi";
        body += "\n    echo \"mtime=$(stat -c %Y \"$f\" 2>/dev/null)\"";
        return $"[ -n \"$(si_pick \"$d\" '{r.File}')\" ]; then\n    " + body;
    }

    /// LAMMPS：从最后一个 run 命令开始读 log.lammps。（⇥ 是制表符，和 Swift 版一样放进正则的字符集里。）
    static readonly string LammpsAwk = """
        awk 'function isnum(x) { return x ~ /^[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$/ }
        NR == 1 { total = $2; if (NF < 2 || $2 !~ /^[0-9]+$/) bad = 1
                  for (i = 3; i <= NF; i++) if ($i == "upto" || $i == "every") bad = 1; next }
        /^[ ⇥]*(minimize|rerun)([ ⇥]|$)/ { bad = 1 }
        /^Loop time of/ { if (hdr) loop = 1; next }
        loop { next }
        !hdr { k = 0; for (i = 1; i <= NF; i++) if ($i == "Step") k = i
               if (k) { hdr = 1; n = NF }; next }
        $k == "Step" { bad = 1; next }
        NF == n { ok = 1; for (i = 1; i <= NF; i++) if (!isnum($i)) { ok = 0; break }
                  if (ok && $k ~ /^[0-9]+$/) { if (first == "") first = $k; last = $k } }
        END { print "total=" total; print "first=" first; print "last=" last; print "loop=" (loop ? 1 : 0); print "bad=" (bad ? 1 : 0) }'
        """.Replace('⇥', '\t');

    /// VASP：INCAR 里的 NSW / IBRION（去掉注释，支持分号分隔），OSZICAR 末尾的离子步 / 电子步。
    static readonly string VaspIncarAwk = """
        awk '{ sub(/[!#].*/, ""); n = split($0, parts, ";")
               for (i = 1; i <= n; i++) { s = toupper(parts[i])
                 if (s ~ /^[ ⇥]*NSW[ ⇥]*=/) { sub(/^[^=]*=[ ⇥]*/, "", s); split(s, v, " "); print "nsw=" v[1] }
                 if (s ~ /^[ ⇥]*IBRION[ ⇥]*=/) { sub(/^[^=]*=[ ⇥]*/, "", s); split(s, v, " "); print "ibrion=" v[1] }
                 if (s ~ /^[ ⇥]*IMAGES[ ⇥]*=/) { sub(/^[^=]*=[ ⇥]*/, "", s); split(s, v, " "); print "images=" v[1] } } }'
        """.Replace('⇥', '\t');

    const string VaspOszicarAwk = """
        awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[FT]=/ { ion = $1 }
             /^[A-Z][A-Z][A-Z ]:/ { s = substr($0, 5); split(s, a, " "); if (a[1] ~ /^[0-9]+$/) elec = a[1] }
             END { print "ionic=" ion; print "elec=" elec }'
        """;

    static string BuiltinBranches => $$"""
        [ -f "$d/loss.out" ] && [ -f "$d/nep.in" ]; then
            printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=nep
            awk '$1=="generation" && $2~/^[0-9]+$/ {print "total="$2; exit}' "$d/nep.in"
            echo "last=$(tail -n 1 "$d/loss.out")"; echo "mtime=$(stat -c %Y "$d/loss.out" 2>/dev/null)"
          elif [ -f "$d/loss.out" ] && [ -f "$d/gnep.in" ]; then
            printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=gnep
            awk '$1=="epoch" && $2~/^[0-9]+$/ {print "total="$2; exit}' "$d/gnep.in"
            echo "last=$(tail -n 1 "$d/loss.out")"; echo "mtime=$(stat -c %Y "$d/loss.out" 2>/dev/null)"
          elif [ -f "$d/run.in" ] && { [ -f "$d/neighbor.out" ] || [ -f "$d/thermo.out" ]; }; then
            printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=gpumd
            awk '$1=="run" && $2~/^[0-9]+$/ {s+=$2} END {if (s>0) print "total="s}' "$d/run.in"
            awk '$1=="dump_thermo" && $2~/^[0-9]+$/ && $2>0 {print "interval="$2; exit}' "$d/run.in"
            if [ -f "$d/neighbor.out" ]; then
              echo "neighbor=$(tail -n 1 "$d/neighbor.out")"; echo "mtime=$(stat -c %Y "$d/neighbor.out" 2>/dev/null)"
            else
              echo "thermo_rows=$(grep -cv '^[[:space:]]*#' "$d/thermo.out")"; echo "mtime=$(stat -c %Y "$d/thermo.out" 2>/dev/null)"
            fi
          elif [ -f "$d/INCAR" ] && [ -f "$d/01/OSZICAR" ] && grep -qiE '^[[:space:]]*IMAGES[[:space:]]*=[[:space:]]*[1-9]' "$d/INCAR"; then
            printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=vasp; echo neb=1
            {{VaspIncarAwk}} "$d/INCAR"
            tail -n 3000 "$d/01/OSZICAR" | {{VaspOszicarAwk}}
            for s in "$d"/[0-9][0-9]; do
              [ -f "$s/OUTCAR" ] && tail -n 25000 "$s/OUTCAR" | awk -v i="${s##*/}" '/energy  without entropy/ { e = $NF } /FORCES: max atom, RMS/ { f = $5 } END { print "nebimg=" i "|" e "|" f }'
            done
            if [ -f "$d/01/OUTCAR" ]; then
              if tail -n 400 "$d/01/OUTCAR" | grep -q 'General timing and accounting'; then echo done=1; else echo done=0; fi
            fi
            echo "mtime=$(stat -c %Y "$d/01/OSZICAR" 2>/dev/null)"
          elif [ -f "$d/INCAR" ] && [ -f "$d/OSZICAR" ]; then
            printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=vasp
            {{VaspIncarAwk}} "$d/INCAR"
            tail -n 3000 "$d/OSZICAR" | {{VaspOszicarAwk}}
            if [ -f "$d/OUTCAR" ]; then
              if tail -n 400 "$d/OUTCAR" | grep -q 'General timing and accounting'; then echo done=1; else echo done=0; fi
            fi
            echo "mtime=$(stat -c %Y "$d/OSZICAR" 2>/dev/null)"
          elif [ -f "$d/log.lammps" ]; then
            L=$(grep -naE '^[[:space:]]*run[[:space:]]' "$d/log.lammps" | tail -n 1 | cut -d: -f1)
            if [ -n "$L" ]; then
              printf '{{Marker}}DIR %s|%s\n' "$id" "$d"; echo kind=lammps
              tail -n +"$L" "$d/log.lammps" | {{LammpsAwk}}
              if tail -n 30 "$d/log.lammps" | grep -q '^Total wall time'; then echo done=1; else echo done=0; fi
              echo "mtime=$(stat -c %Y "$d/log.lammps" 2>/dev/null)"
            fi
        """;

    static readonly Regex NeighborRegex = new(@"^Neighbor info at step\s+(\d+):\s*radial\(max=(\d+),actual=(\d+)\),\s*angular\(max=(\d+),actual=(\d+)\)");

    static readonly Dictionary<string, AppKind> Kinds = new()
    {
        ["nep"] = AppKind.Nep, ["gnep"] = AppKind.Gnep, ["gpumd"] = AppKind.Gpumd,
        ["vasp"] = AppKind.Vasp, ["lammps"] = AppKind.Lammps, ["custom"] = AppKind.Custom,
    };

    /// 解析 "apps" 段：返回 任务ID -> 进度。`rules`：解析自定义规则用的规则表（默认是当前设置里的）。
    public static Dictionary<string, AppProgress> Parse(IEnumerable<string> lines, IReadOnlyList<ProgressRule>? rules = null)
    {
        var outMap = new Dictionary<string, AppProgress>();
        string? id = null;
        var dir = "";
        var kv = new Dictionary<string, string>();
        var tails = new List<string>();
        var nebImgs = new List<string>();

        void Flush()
        {
            try
            {
                if (id == null || !kv.TryGetValue("kind", out var k) || !Kinds.TryGetValue(k, out var kind)) return;
                var p = new AppProgress(kind, dir);
                if (Text.Dbl(kv.GetValueOrDefault("mtime")) is { } mt) p.UpdatedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(mt * 1000)).LocalDateTime;
                switch (kv.GetValueOrDefault("done"))
                {
                    case "1": p.EndMarker = true; break;
                    case "0": p.EndMarker = false; break;
                }
                switch (kind)
                {
                    case AppKind.Nep or AppKind.Gnep:
                        if (Text.Dbl(kv.GetValueOrDefault("total")) is { } t) p.Total = t;
                        else { p.Total = kind == AppKind.Nep ? 100_000 : 50; p.HasTarget = false; }
                        var nums = Text.Words(kv.GetValueOrDefault("last") ?? "").Select(Text.Dbl).Where(v => v != null).Select(v => v!.Value).ToList();
                        if (nums.Count > 0)
                        {
                            p.Current = nums[0];
                            // loss.out 列：gen Total L1 L2 E-train F-train V-train [E-test F-test V-test]（与 plt_train.py 一致）
                            string[] labels = nums.Count >= 7
                                ? ["Total", "L1", "L2", "Energy", "Force", "Virial", "E-test", "F-test", "V-test"]
                                : ["Loss", "Energy", "Force", "Virial"];
                            for (int i = 1; i < nums.Count && i - 1 < labels.Length; i++)
                                p.Losses.Add(new AppProgress.Value(labels[i - 1], nums[i]));
                            // 没有测试集时 test 列全是 0，不显示。
                            var tests = p.Losses.Where(l => l.Label.EndsWith("-test")).ToList();
                            if (tests.Count > 0 && tests.All(l => l.V == 0)) p.Losses.RemoveAll(l => l.Label.EndsWith("-test"));
                        }
                        break;
                    case AppKind.Gpumd:
                        p.Total = Text.Dbl(kv.GetValueOrDefault("total"));
                        p.HasTarget = p.Total != null;
                        if (kv.GetValueOrDefault("neighbor") is { } line && NeighborRegex.Match(line) is { Success: true } m)
                        {
                            var n = Enumerable.Range(1, 5).Select(i => Text.Int(m.Groups[i].Value) ?? 0).ToArray();
                            p.Current = n[0];
                            p.Neigh = new AppProgress.Neighbor(n[2], n[1], n[4], n[3]);
                        }
                        else if (Text.Dbl(kv.GetValueOrDefault("thermo_rows")) is { } rows && Text.Dbl(kv.GetValueOrDefault("interval")) is { } iv)
                            p.Current = rows * iv;
                        break;
                    case AppKind.Vasp:
                        if (ParseVasp(kv) is not { } v) return;
                        p.Vasp = v.Mode; p.Current = v.Current; p.Total = v.Total; p.HasTarget = v.Total != null;
                        if (v.Mode == VaspMode.Neb)
                        {
                            var images = Text.Int(kv.GetValueOrDefault("images"));
                            (p.NebBarrier, p.NebForce) = ParseNeb(nebImgs, images);
                            p.NebImages = images;
                        }
                        break;
                    case AppKind.Lammps:
                        if (ParseLammps(kv) is not { } l) return;
                        p.Current = l.Current; p.Total = l.Total;
                        break;
                    case AppKind.Custom:
                        if (!Guid.TryParse(kv.GetValueOrDefault("rule"), out var rid)) return;
                        var rule = (rules ?? ProgressRule.Active).FirstOrDefault(r => r.Id == rid);
                        if (rule == null || rule.Extract(tails) is not { } x) return;
                        p.CustomName = rule.Name;
                        p.CustomUnit = rule.Unit;
                        p.Current = x.Current;
                        p.Total = x.Total ?? Text.Dbl(rule.Total)
                            ?? (kv.GetValueOrDefault("totalline") is { } tl ? ProgressRule.NumberAfter(rule.TotalKeyword, tl) : null);
                        if (p.Total is { } tt)
                        {
                            // 目标值不合理或当前值超过目标值：当作没识别到
                            if (!(tt > 0 && x.Current >= 0 && x.Current <= tt * 1.000001)) return;
                        }
                        p.HasTarget = p.Total != null;
                        if (rule.DoneMarker.Length == 0) p.EndMarker = null;
                        break;
                }
                outMap[id] = p;
            }
            finally
            {
                kv = new Dictionary<string, string>();
                tails = [];
                nebImgs = [];
            }
        }

        foreach (var line in lines)
        {
            if (line.StartsWith(Marker + "DIR ", StringComparison.Ordinal))
            {
                Flush();
                var rest = line[(Marker + "DIR ").Length..];
                int bar = rest.IndexOf('|');
                if (bar >= 0) { id = rest[..bar]; dir = rest[(bar + 1)..]; } else id = null;
            }
            else if (line.StartsWith("tail=", StringComparison.Ordinal)) tails.Add(line[5..]);
            else if (line.StartsWith("nebimg=", StringComparison.Ordinal)) nebImgs.Add(line[7..]);
            else if (line.IndexOf('=') is var eq and >= 0) kv[line[..eq]] = line[(eq + 1)..];
        }
        Flush();
        return outMap;
    }

    /// VASP：NSW ≤ 0 → 单点（电子步）；IBRION=0 → MD（离子步 / NSW）；IBRION=1/2/3 → 结构优化（只显示离子步）。
    public static (VaspMode Mode, double Current, double? Total)? ParseVasp(IReadOnlyDictionary<string, string> kv)
    {
        // NEB：只显示离子步（01 像点的 OSZICAR），不按 NSW 算百分比（一般早于 NSW 收敛）
        if (kv.GetValueOrDefault("neb") == "1")
            return Text.Int(kv.GetValueOrDefault("ionic")) is { } ni ? (VaspMode.Neb, ni, null) : null;
        int nsw = 0;
        int? ibrion = null;
        if (kv.TryGetValue("nsw", out var s1)) { if (Text.Int(s1) is not { } v) return null; nsw = v; }
        if (kv.TryGetValue("ibrion", out var s2)) { if (Text.Int(s2) is not { } v) return null; ibrion = v; }
        var ionic = Text.Int(kv.GetValueOrDefault("ionic"));
        var elec = Text.Int(kv.GetValueOrDefault("elec"));
        if (nsw <= 0) return elec is { } e ? (VaspMode.Scf, e, null) : null;
        switch (ibrion ?? 0)
        {
            case 0:
                if (ionic is not { } i || i > nsw) return null;
                return (VaspMode.Md, i, nsw);
            case 1 or 2 or 3:
                if (ionic is not { } r) return null;
                return (VaspMode.Relax, r, null);
            default:
                return null;
        }
    }

    /// NEB 各像点（`编号|能量|VTST 力`，来自每个像点 OUTCAR 的末尾）：
    /// 能垒 = 除初态外最高的能量 − 初态（00）能量，和 VTST 的 nebef.pl 一样用 energy(sigma→0)；
    /// 最大力 = 中间像点（1…IMAGES）里最大的 VTST `FORCES: max atom`。缺数据时对应的值为 null。
    public static (double? Barrier, double? Force) ParseNeb(IEnumerable<string> lines, int? images)
    {
        var energy = new Dictionary<int, double>();
        var force = new Dictionary<int, double>();
        foreach (var l in lines)
        {
            var f = l.Split('|');
            if (f.Length != 3 || Text.Int(f[0]) is not { } i) continue;
            if (Text.Dbl(f[1]) is { } e) energy[i] = e;
            if (Text.Dbl(f[2]) is { } v) force[i] = v;
        }
        int last = images is { } n ? n + 1 : (energy.Count > 0 ? energy.Keys.Max() : 0);
        double? barrier = null;
        if (energy.TryGetValue(0, out var e0) && energy.Where(kv => kv.Key > 0).Select(kv => kv.Value).ToList() is { Count: > 0 } others)
            barrier = others.Max() - e0;
        var middle = force.Where(kv => kv.Key >= 1 && kv.Key < last).Select(kv => kv.Value).ToList();
        return (barrier, middle.Count > 0 ? middle.Max() : null);
    }

    /// LAMMPS：当前步 = 最后一行的 Step − 这段 run 第一行的 Step，目标 = run 的步数。任何一处不对就返回 nil。
    public static (double Current, double Total)? ParseLammps(IReadOnlyDictionary<string, string> kv)
    {
        if (kv.GetValueOrDefault("bad") != "0") return null;
        if (Text.Dbl(kv.GetValueOrDefault("total")) is not { } total || total <= 0) return null;
        if (Text.Dbl(kv.GetValueOrDefault("first")) is not { } first || Text.Dbl(kv.GetValueOrDefault("last")) is not { } last) return null;
        var cur = last - first;
        if (cur < 0 || cur > total) return null;
        return (cur, total);
    }

    // MARK: - 设置页"测试规则"

    /// 先报告目录和文件是否存在，再跑这一条规则（不跑内置识别）。只读。
    public static string RuleTestScript(string dir, ProgressRule rule)
    {
        var s = $"""
            {JobIDFunction}
            d={Q(dir)}
            case "$d" in "~"/*) d="$HOME/${"{"}d#\~/{"}"}";; esac
            if [ ! -d "$d" ]; then echo '{Marker}NODIR'; else
              echo "picked=$(si_pick "$d" '{rule.File}')"

            """;
        if (rule.TotalFile.Length > 0) s += $"  echo \"tpicked=$(si_pick \"$d\" '{rule.TotalFile}')\"\n";
        if (rule.Match == RuleMatch.Keyword)
        {
            // 没匹配上时给用户看文件最后几行
            s += $"  f=\"$d/$(si_pick \"$d\" '{rule.File}')\"; [ -f \"$f\" ] && tail -n 5 \"$f\" | cut -c1-200 | sed 's/^/last=/'\n";
        }
        s += "fi\n";
        return s + DirectoryScript("t", dir, [rule], builtin: false);
    }

    public static RuleTestResult InterpretTest(string stdout, ProgressRule rule)
    {
        var lines = stdout.Split('\n');
        if (lines.Contains(Marker + "NODIR")) return new RuleTestResult { Headline = L("服务器上没有这个目录", "Directory not found on the server") };
        string? Value(string key) => lines.FirstOrDefault(l => l.StartsWith(key + "=", StringComparison.Ordinal)) is { } l ? l[(key.Length + 1)..] : null;
        if (Value("picked") is not { } picked) return new RuleTestResult { Headline = L("没有收到服务器的回应", "No response from the server") };
        if (picked.Length == 0)
            return new RuleTestResult { Headline = L($"目录里没有匹配「{rule.File}」的文件", $"No file matching “{rule.File}” in this directory") };
        var notes = new List<string> { L("文件：", "File: ") + picked };
        if (rule.TotalFile.Length > 0 && string.IsNullOrEmpty(Value("tpicked")))
            notes.Add(L($"没找到目标值文件「{rule.TotalFile}」", $"Target file “{rule.TotalFile}” not found"));
        if (Parse(lines, [rule]).GetValueOrDefault("t") is { Current: { } c } a)
        {
            var head = L("当前值 ", "Current ") + AppProgress.Compact(c);
            if (a.Total is { } t)
            {
                head += L(" · 目标值 ", " · target ") + AppProgress.Compact(t);
                if (a.Fraction is { } f) head += $"（{Format.Percent(f)}）";
            }
            else head += L(" · 没有目标值，只显示当前值", " · no target, showing the current value only");
            if (a.EndMarker is { } m) notes.Add(m ? L("已出现结束标记", "End marker found") : L("还没有出现结束标记", "End marker not found yet"));
            return new RuleTestResult { Ok = true, Headline = head, Notes = notes };
        }
        var tails = lines.Where(l => l.StartsWith("tail=", StringComparison.Ordinal)).Select(l => l[5..]).ToList();
        var shown = rule.Match == RuleMatch.Keyword
            ? lines.Where(l => l.StartsWith("last=", StringComparison.Ordinal)).Select(l => l[5..]).ToList()
            : tails.TakeLast(5).ToList();
        if (rule.Extract(tails) is { } x && (x.Total ?? Text.Dbl(rule.Total)) is { } tot)
        {
            return new RuleTestResult
            {
                Headline = L($"当前值 {AppProgress.Compact(x.Current)} 超过了目标值 {AppProgress.Compact(tot)}，不会显示进度",
                             $"Current {AppProgress.Compact(x.Current)} exceeds target {AppProgress.Compact(tot)}; progress won't be shown"),
                Notes = notes, Lines = shown,
            };
        }
        var headline = rule.Match == RuleMatch.Keyword
            ? L($"文件里没有「{rule.Pattern}」后面紧跟数字的行", $"No line has a number right after “{rule.Pattern}”")
            : L("文件最后 40 行都没有匹配上正则", "The regex matched none of the last 40 lines");
        notes.Add(L("文件最后几行：", "Last lines of the file:"));
        return new RuleTestResult { Headline = headline, Notes = notes, Lines = shown };
    }
}
