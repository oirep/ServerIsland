using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 详情页里的小曲线：NEP / GNEP 的 loss，VASP 结构优化每个离子步的能量和最大力（两张并排）。
/// 只在详情页打开时读取，并且是增量的：记住已经读到第几行和文件第一行，下次只取新增的行；
/// 第一行变了（重新训练）或文件变短时从头读。
public sealed class AppCurve
{
    public sealed record Series(string Name, List<(double X, double Y)> Points);

    public string Title = "";
    public List<Series> SeriesList = [];
    /// loss 跨好几个数量级，用对数坐标。
    public bool LogY;
    public string XLabel = "";
    /// 收敛目标（虚线），比如 VASP 的 |EDIFFG|（EDIFFG < 0 时按力收敛）。
    public double? Threshold;
}

/// 增量读取的缓存（每台服务器 + 文件一份）。
public sealed class CurveCache
{
    public int LineCount;
    public string Head = "";
    public List<double[]> Rows = [];
    /// 曲线以外的值（如 ediffg）。
    public Dictionary<string, string> Extra = [];
}

public static class AppCurves
{
    const string Marker = RemoteScript.Marker;
    /// 一次最多取这么多行（第一次打开很长的 loss.out 时只取最后这些）。
    public const int MaxRows = 50_000;

    public enum CurveKind { Loss, VaspEnergy, VaspForce }

    /// VaspForce：OUTCAR 每个离子步 TOTAL-FORCE 块里最大的原子受力 |F|；INCAR 的 EDIFFG 作为收敛目标。
    public sealed record Source(string Path, CurveKind Kind, bool Gnep = false)
    {
        public bool IsLoss => Kind == CurveKind.Loss;
    }

    /// 哪些任务有曲线：NEP / GNEP 训练、VASP 结构优化（能量 + 最大力）。
    public static List<Source> SourcesFor(AppProgress app) => app.Kind switch
    {
        AppKind.Nep => [new Source(app.Dir + "/loss.out", CurveKind.Loss)],
        AppKind.Gnep => [new Source(app.Dir + "/loss.out", CurveKind.Loss, true)],
        AppKind.Vasp when app.Vasp == VaspMode.Relax => [new Source(app.Dir + "/OSZICAR", CurveKind.VaspEnergy), new Source(app.Dir + "/OUTCAR", CurveKind.VaspForce)],
        _ => [],
    };

    /// OUTCAR 的力块：表头一行、虚线、每个原子一行（x y z Fx Fy Fz）、虚线。只在读到第二条虚线时输出这一步，
    /// 并用 n= 报告"读完的最后一个完整块"所在的行，正在写的半个块下次重读。文本和 Swift 版逐字一致。
    public const string ForceAwk = """awk -v off="$off" '/TOTAL-FORCE/ { inb = 1; d = 0; m = 0; next } inb && /^ *-+ *$/ { d++; if (d == 2) { printf "row=0 %.6g\n", sqrt(m); inb = 0; last = NR } ; next } inb && d == 1 && NF >= 6 { f = $4 * $4 + $5 * $5 + $6 * $6; if (f > m) m = f } END { print "n=" off + last }'""";

    /// 远端脚本：输出 n=总行数，必要时 reset=1，然后是 row= 开头的数据行。
    /// `head -n $((n-off))` 只取 wc 数到的完整行，正在写的半行不读，偏移量才对得上。
    public static string Script(Source src, int offset, string head)
    {
        if (src.Kind == CurveKind.VaspForce) return ForceScript(src.Path, offset, head);
        var filter = src.IsLoss
            ? "awk 'NF >= 2 && $1 ~ /^[0-9]+$/ { print }' | cut -c1-300"
            : """awk '$1 ~ /^[0-9]+$/ && $2 ~ /^F=/ { for (i = 3; i <= NF; i++) if ($i ~ /^E0=/) { v = substr($i, 4); if (v == "") v = $(i + 1); print $1, v; break } }'""";
        return $"""
            f={RemoteScript.ShellQuote(src.Path)}
            if [ ! -f "$f" ]; then echo '{Marker}NOFILE'; exit 0; fi
            n=$(wc -l < "$f" | tr -d ' '); h=$(head -n 1 "$f" | cut -c1-200)
            off={Math.Max(0, offset)}
            if [ "$h" != {RemoteScript.ShellQuote(head)} ] || [ "$n" -lt "$off" ]; then off=0; echo reset=1; fi
            if [ $((n - off)) -gt {MaxRows} ]; then off=$((n - {MaxRows})); echo reset=1; fi
            echo "n=$n"; echo "head=$h"
            tail -n +$((off + 1)) "$f" | head -n $((n - off)) | {filter} | sed 's/^/row=/'

            """;
    }

    /// OUTCAR 可能有几十万行：不限制行数（awk 一遍就过去了），增量读取保证之后每次只读新增部分。
    public static string ForceScript(string path, int offset, string head) => $"""
        f={RemoteScript.ShellQuote(path)}
        if [ ! -f "$f" ]; then echo '{Marker}NOFILE'; exit 0; fi
        n=$(wc -l < "$f" | tr -d ' '); h=$(head -n 1 "$f" | cut -c1-200)
        off={Math.Max(0, offset)}
        if [ "$h" != {RemoteScript.ShellQuote(head)} ] || [ "$n" -lt "$off" ]; then off=0; echo reset=1; fi
        echo "head=$h"
        sed -n 's/^[[:space:]]*EDIFFG[[:space:]]*=[[:space:]]*\([-+.0-9eEdD]*\).*/ediffg=\1/p' "$(dirname "$f")/INCAR" 2>/dev/null | tail -n 1
        tail -n +$((off + 1)) "$f" | head -n $((n - off)) | {ForceAwk}

        """;

    /// 把一次输出合并进缓存。读不到文件时返回 null。
    public static CurveCache? Merge(string stdout, CurveCache cache)
    {
        var lines = stdout.Split('\n');
        if (lines.Contains(Marker + "NOFILE")) return null;
        var nLine = lines.FirstOrDefault(l => l.StartsWith("n=", StringComparison.Ordinal));
        if (nLine == null || Text.Int(nLine[2..]) is not { } n) return null;
        var c = new CurveCache { LineCount = cache.LineCount, Head = cache.Head, Rows = [.. cache.Rows], Extra = new(cache.Extra) };
        if (lines.Contains("reset=1")) c.Rows = [];
        c.LineCount = n;
        c.Head = lines.FirstOrDefault(l => l.StartsWith("head=", StringComparison.Ordinal)) is { } h ? h[5..] : "";
        if (lines.FirstOrDefault(l => l.StartsWith("ediffg=", StringComparison.Ordinal)) is { } e) c.Extra["ediffg"] = e[7..];
        foreach (var l in lines.Where(l => l.StartsWith("row=", StringComparison.Ordinal)))
        {
            var nums = Text.Words(l[4..]).Select(Text.Dbl).Where(v => v != null).Select(v => v!.Value).ToArray();
            if (nums.Length >= 2) c.Rows.Add(nums);
        }
        return c;
    }

    public static AppCurve? Curve(Source src, List<double[]> rows, Dictionary<string, string>? extra = null)
    {
        if (rows.Count < 2) return null;
        if (src.Kind == CurveKind.VaspForce)
        {
            // 力块按顺序就是离子步 1、2、3…
            var pts = rows.Select((r, i) => ((double)(i + 1), Math.Max(r[1], 1e-6))).ToList();
            // EDIFFG < 0：按力收敛，|EDIFFG| 就是目标（eV/Å）；Fortran 的 d 指数也认。
            double? target = extra?.GetValueOrDefault("ediffg") is { } ed && Text.Dbl(ed.Replace('d', 'e').Replace('D', 'e')) is { } v && v < 0 ? -v : null;
            return new AppCurve
            {
                Title = L("最大力（eV/Å）", "Max force (eV/Å)"),
                SeriesList = [new AppCurve.Series("|F|max", Downsample(pts))],
                LogY = true,
                XLabel = L("离子步", "ionic step"),
                Threshold = target,
            };
        }
        if (src.IsLoss)
        {
            // NEP：gen Total L1 L2 E F V [E-test F-test V-test]；GNEP：epoch Loss E F V
            (string, int)[] cols = src.Gnep
                ? [("Loss", 1), (L("能量", "Energy"), 2), (L("力", "Force"), 3), (L("维里", "Virial"), 4)]
                : rows[^1].Length >= 7
                    ? [("Total", 1), (L("能量", "Energy"), 4), (L("力", "Force"), 5), (L("维里", "Virial"), 6)]
                    : [("Loss", 1), (L("能量", "Energy"), 2), (L("力", "Force"), 3), (L("维里", "Virial"), 4)];
            var series = new List<AppCurve.Series>();
            foreach (var (name, i) in cols)
            {
                var pts = rows.Where(r => i < r.Length && r[i] > 0).Select(r => (r[0], r[i])).ToList();
                if (pts.Count >= 2) series.Add(new AppCurve.Series(name, Downsample(pts)));
            }
            if (series.Count == 0) return null;
            return new AppCurve { Title = "Loss", SeriesList = series, LogY = true, XLabel = src.Gnep ? "epoch" : L("代", "gen") };
        }
        var e0 = rows.Select(r => (r[0], r[1])).ToList();
        return new AppCurve
        {
            Title = L("能量 E0（eV）", "Energy E0 (eV)"),
            SeriesList = [new AppCurve.Series("E0", Downsample(e0))],
            LogY = false,
            XLabel = L("离子步", "ionic step"),
        };
    }

    /// 点太多时等间隔抽样（保留首尾），画图用不到上万个点。
    public static List<(double, double)> Downsample(List<(double, double)> pts, int limit = 400)
    {
        if (pts.Count <= limit) return pts;
        double step = (double)(pts.Count - 1) / (limit - 1);
        return Enumerable.Range(0, limit).Select(k => pts[Math.Min((int)Math.Round(k * step, MidpointRounding.AwayFromZero), pts.Count - 1)]).ToList();
    }
}
