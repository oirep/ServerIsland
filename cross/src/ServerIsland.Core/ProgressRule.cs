using System.Text.Json.Serialization;
using System.Text.RegularExpressions;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

public enum RuleMatch { Keyword, Regex }
public enum RuleSource { File, ActionLog }
public enum LogRuleMode { Numbered, Stages }

public sealed class LogRuleStage
{
    [JsonConverter(typeof(UpperGuidConverter))]
    public Guid Id { get; set; } = Guid.NewGuid();
    public string Name { get; set; } = "";
    public string Pattern { get; set; } = "";
}

/// 用户自定义的进度识别规则：任务的工作目录里有某个文件，就从这个文件里取"当前值"和"目标值"。
/// 保存在全局设置里，对所有服务器生效。规则在内置识别（NEP / GPUMD / VASP / LAMMPS）之前检查。
/// 任何一步对不上（文件没有、数字取不到、当前值超过目标值）都当作没识别到，不显示进度。
public sealed class ProgressRule
{
    public RuleSource Source { get; set; } = RuleSource.File;
    public LogRuleMode LogMode { get; set; } = LogRuleMode.Numbered;
    public string ActivationPattern { get; set; } = "";
    public int CurrentGroup { get; set; } = 1;
    public int TotalGroup { get; set; } = 2;
    public int LabelGroup { get; set; } = 3;
    public List<LogRuleStage> Stages { get; set; } = [];
    [JsonConverter(typeof(UpperGuidConverter))]
    public Guid Id { get; set; } = Guid.NewGuid();
    public bool Enabled { get; set; } = true;
    public string Name { get; set; } = "";
    /// 工作目录里的文件名，可以用 * ? 通配（取最新的一个）。
    public string File { get; set; } = "";
    public RuleMatch Match { get; set; } = RuleMatch.Keyword;
    /// 关键字或正则。
    public string Pattern { get; set; } = "";
    /// 固定的目标值（为空且没有从文件里取到时，只显示当前值）。
    public string Total { get; set; } = "";
    /// 从另一个文件里取目标值：文件名 + 关键字（取第一次出现时后面的数字）。
    public string TotalFile { get; set; } = "";
    public string TotalKeyword { get; set; } = "";
    /// 正常结束的标记文字（可选）。
    public string DoneMarker { get; set; } = "";
    public string Unit { get; set; } = "";

    public string IdString => Id.ToString("D").ToUpperInvariant();

    public ProgressRule Clone() => Json.Clone(this);

    public static string MatchLabel(RuleMatch m) => m == RuleMatch.Keyword ? L("关键字", "Keyword") : L("正则", "Regex");

    /// 文件名只允许常见字符（会原样放进远端 shell 做通配）。
    public static bool IsSafeFileName(string s) =>
        s.Length > 0 && s.Length <= 120 && !s.StartsWith('/') && !s.Contains("..")
        && s.All(c => c < 128 && (char.IsLetterOrDigit(c) || "._-*?/+".Contains(c)));

    /// 规则是否完整可用；不可用时返回原因（设置页里显示）。
    [JsonIgnore]
    public string? Problem
    {
        get
        {
            if (Name.Trim().Length == 0) return L("还没有填名称", "Name is empty");
            if (Source == RuleSource.ActionLog)
            {
                bool Valid(string value) {
                    if (value.Length is 0 or > 1000) return false;
                    try { _ = new Regex(value); return true; } catch { return false; }
                }
                if (ActivationPattern.Length > 0 && !Valid(ActivationPattern)) return L("激活正则无效", "Invalid activation regex");
                if (LogMode == LogRuleMode.Stages)
                    return Stages.Count is 0 or > 100 || Stages.Any(s => s.Name.Length == 0 || !Valid(s.Pattern))
                        ? L("阶段名称或正则无效", "Invalid stage name or regex") : null;
                if (!Valid(Pattern)) return L("日志正则无效", "Invalid log regex");
                var count = new Regex(Pattern).GetGroupNumbers().Length - 1;
                if (CurrentGroup < 1 || CurrentGroup > count || LabelGroup < 0 || LabelGroup > count)
                    return L("捕获组超出范围", "Capture group out of range");
                if (Total.Length > 0)
                    return !int.TryParse(Total, out var total) || total is < 1 or > 1000
                        ? L("固定总阶段数无效", "Invalid fixed stage total") : null;
                return TotalGroup < 1 || TotalGroup > count ? L("总数捕获组无效", "Invalid total group") : null;
            }
            if (!IsSafeFileName(File)) return L("文件名为空或含有不支持的字符", "File name is empty or has unsupported characters");
            if (Pattern.Length == 0) return Match == RuleMatch.Keyword ? L("还没有填关键字", "Keyword is empty") : L("还没有填正则", "Regex is empty");
            if (Match == RuleMatch.Regex)
            {
                Regex re;
                try { re = new Regex(Pattern); } catch { return L("正则写法有误", "Invalid regex"); }
                if (re.GetGroupNumbers().Length < 2) return L("正则里需要至少一个捕获组 ( )，代表当前值", "The regex needs a capture group ( ) for the current value");
            }
            if (Total.Length > 0 && Text.Dbl(Total) == null) return L("目标值需要是数字", "Target must be a number");
            if (TotalFile.Length > 0 && !IsSafeFileName(TotalFile)) return L("目标值文件名含有不支持的字符", "Target file name has unsupported characters");
            if (TotalFile.Length > 0 && TotalKeyword.Length == 0) return L("从文件取目标值时需要填关键字", "A keyword is needed to read the target from a file");
            return null;
        }
    }

    [JsonIgnore] public bool IsUsable => Source == RuleSource.File && Enabled && Problem == null;

    /// 当前生效的规则（由 ConfigStore 更新，生成远端脚本时读取）。
    public static List<ProgressRule> Active = [];

    /// 在若干行里（从最后一行往前）找当前值和目标值。
    public (double Current, double? Total)? Extract(IReadOnlyList<string> lines)
    {
        Regex? re;
        if (Match == RuleMatch.Keyword) re = KeywordRegex(Pattern);
        else
        {
            try { re = new Regex(Pattern); } catch { return null; }
        }
        for (int i = lines.Count - 1; i >= 0; i--)
        {
            if (FirstMatch(re, lines[i]) is { } m && m[0] is { } c)
                return (c, m.Count > 1 ? m[1] : null);
        }
        return null;
    }

    /// 关键字后面的数字：允许中间有空格、冒号、等号、#；后面可以跟 "/ 目标值" 或 "of 目标值"。不区分大小写。
    public static Regex? KeywordRegex(string kw)
    {
        try
        {
            return new Regex(Regex.Escape(kw) + @"\s*[:=#]?\s*(-?\d+(?:\.\d+)?)(?:\s*(?:/|of)\s*(\d+(?:\.\d+)?))?", RegexOptions.IgnoreCase);
        }
        catch { return null; }
    }

    /// 目标值文件里"关键字后面的数字"（第一次出现）。
    public static double? NumberAfter(string kw, string line) => FirstMatch(KeywordRegex(kw), line) is { } m ? m[0] : null;

    static List<double?>? FirstMatch(Regex? re, string line)
    {
        if (re == null) return null;
        var m = re.Match(line);
        if (!m.Success) return null;
        var groups = re.GetGroupNumbers().Length;   // 含第 0 组
        var outList = new List<double?>();
        for (int i = 1; i < Math.Max(groups, 2); i++)
        {
            var g = i < groups ? m.Groups[i] : null;
            outList.Add(g is { Success: true } ? Text.Dbl(g.Value.Replace(",", "")) : null);
        }
        if (outList.Count == 0 || outList[0] == null) return null;
        return outList;
    }
}
