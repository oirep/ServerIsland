using System.Text.RegularExpressions;

namespace ServerIsland.Core;

/// Slurm 分区的空闲资源（按需查询，不参与轮询）。
public sealed class PartitionStat
{
    public string Name = "";
    public bool IsDefault;
    public bool Available = true;
    public string TimeLimit = "";
    public int Nodes, IdleNodes, MixNodes, AllocNodes, DownNodes;
    public int CpuIdle, CpuTotal;
    /// 加速卡（GPU，或曙光的 DCU 等）合在一起算；GpuKinds 记下出现过的种类，界面按它显示"GPU" / "DCU"。
    public int GpuIdle, GpuTotal;
    public SortedSet<string> GpuModels = [];
    public SortedSet<string> GpuKinds = [];

    /// 加速卡的名字：只有一种时就是它（DCU），混在一起时用"/"连起来，没有时是 GPU。
    public string GpuLabel => Label(GpuKinds);

    public static string Label(IEnumerable<string> kinds)
    {
        var k = kinds.Select(x => x.ToUpperInvariant()).Distinct().Order(StringComparer.Ordinal).ToList();
        return k.Count == 0 ? "GPU" : string.Join("/", k);
    }
}

public static class Partitions
{
    public static string Script(HostConfig host)
    {
        var s = host.Commands.Preamble.Length > 0 ? host.Commands.Preamble + "\n" : "";
        const string m = RemoteScript.Marker;
        s += $"""
            printf '{m}SEC summary\n'; sinfo -h -o '%P|%a|%l' 2>&1; printf '{m}RC %s\n' "$?"
            printf '{m}SEC nodes\n'; sinfo -N -h -O 'NodeList:80,Partition:60,StateCompact:20,CPUsState:30,Gres:200,GresUsed:240' 2>&1; printf '{m}RC %s\n' "$?"

            """;
        return s;
    }

    /// 认作加速卡的 Gres 名字：NVIDIA / AMD 的 gpu，曙光（海光）的 dcu，昇腾的 npu，寒武纪的 mlu。
    static readonly Regex GpuRegex = new(@"(?<![A-Za-z0-9_])(gpu|dcu|npu|mlu)(?::([^:(,\s]+))?:(\d+)");

    /// "gpu:V100-SXM2:4(S:0-1)" -> (4, ["V100-SXM2"], ["gpu"])；"gpu:a100:2(IDX:0-1),gpu:v100:1" 会相加；
    /// 曙光的 "dcu:Hygon:4(S:0-3)" -> (4, ["Hygon"], ["dcu"])。数量为 0 的种类（GresUsed 里的 "dcu:0,gpu:0"）不算。
    public static (int Count, HashSet<string> Models, HashSet<string> Kinds) GpuCount(string s)
    {
        if (s == "(null)") return (0, [], []);
        int n = 0;
        HashSet<string> models = [], kinds = [];
        foreach (Match m in GpuRegex.Matches(s))
        {
            int k = Text.Int(m.Groups[3].Value) ?? 0;
            if (k <= 0) continue;
            n += k;
            kinds.Add(m.Groups[1].Value);
            if (m.Groups[2].Success) models.Add(m.Groups[2].Value);
        }
        return (n, models, kinds);
    }

    public static List<PartitionStat>? Parse(RemoteScript.Parsed parsed)
    {
        if (parsed.Get("nodes") is not { ExitCode: 0 } nodes) return null;
        var map = new Dictionary<string, PartitionStat>();
        var order = new List<string>();

        static (string, bool) Key(string raw) => raw.EndsWith('*') ? (raw[..^1], true) : (raw, false);

        if (parsed.Get("summary") is { ExitCode: 0 } sum)
        {
            foreach (var line in sum.Lines)
            {
                var f = line.Split('|');
                if (f.Length < 3 || f[0].Length == 0) continue;
                var (name, def) = Key(f[0]);
                if (!map.TryGetValue(name, out var p)) { p = new PartitionStat { Name = name }; order.Add(name); map[name] = p; }
                p.IsDefault = def;
                p.Available = f[1] == "up";
                p.TimeLimit = f[2];
            }
        }

        foreach (var line in nodes.Lines)
        {
            var f = Text.Words(line);
            if (f.Count < 4) continue;
            var (name, def) = Key(f[1]);
            if (!map.TryGetValue(name, out var p)) { p = new PartitionStat { Name = name }; order.Add(name); map[name] = p; }
            if (def) p.IsDefault = true;
            var state = f[2].ToLowerInvariant().Trim("*~#!%$@^-+".ToCharArray());
            bool usable = !(state.StartsWith("down") || state.StartsWith("drain") || state.StartsWith("drng")
                            || state.StartsWith("fail") || state.StartsWith("maint") || state.StartsWith("unk")
                            || state.StartsWith("boot") || state.StartsWith("powered") || state.StartsWith("inval"));
            p.Nodes += 1;
            if (!usable) p.DownNodes += 1;
            else if (state.StartsWith("idle")) p.IdleNodes += 1;
            else if (state.StartsWith("mix")) p.MixNodes += 1;
            else p.AllocNodes += 1;

            var cpu = f[3].Split('/').Select(Text.Int).Where(v => v != null).Select(v => v!.Value).ToList();   // A/I/O/T
            if (cpu.Count == 4)
            {
                p.CpuTotal += cpu[3];
                if (usable) p.CpuIdle += cpu[1];
            }
            if (f.Count >= 5)
            {
                var (total, models, kinds) = GpuCount(f[4]);
                int used = f.Count >= 6 ? GpuCount(f[5]).Count : 0;
                p.GpuTotal += total;
                p.GpuModels.UnionWith(models);
                p.GpuKinds.UnionWith(kinds);
                if (usable) p.GpuIdle += Math.Max(0, total - used);
            }
        }
        return order.Select(n => map[n]).OrderByDescending(p => p.GpuIdle).ThenByDescending(p => p.CpuIdle).ToList();
    }
}
