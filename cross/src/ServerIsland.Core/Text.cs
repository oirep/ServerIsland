using System.Globalization;
using static ServerIsland.Core.Lang;

namespace ServerIsland.Core;

/// 与 Swift 版行为一致的小工具：数字解析、按空白切分、路径末段等。
public static class Text
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
    const NumberStyles FloatStyle = NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint | NumberStyles.AllowExponent;

    /// 和 Swift 的 Double(String) 一样：不允许前后空白。
    public static double? Dbl(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        if (s == "inf" || s == "+inf") return double.PositiveInfinity;
        if (s == "-inf") return double.NegativeInfinity;
        return double.TryParse(s, FloatStyle, Inv, out var v) ? v : null;
    }

    /// 和 Swift 的 Int(String) 一样：只允许可选符号 + 数字。
    public static int? Int(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        return int.TryParse(s, NumberStyles.AllowLeadingSign, Inv, out var v) ? v : null;
    }

    public static bool IsAllDigits(string s) => s.Length > 0 && s.All(char.IsDigit);

    /// Swift 的 `split(separator:)`（默认丢掉空段）。
    public static List<string> Words(string s, char sep = ' ') =>
        s.Split(sep, StringSplitOptions.RemoveEmptyEntries).ToList();

    /// Swift 的 `split(separator:maxSplits:omittingEmptySubsequences: true)`：最后一段保留剩余原文。
    public static List<string> SplitMax(string s, char sep, int maxSplits)
    {
        var result = new List<string>();
        int start = 0, i = 0;
        while (i < s.Length)
        {
            if (s[i] == sep)
            {
                if (i > start) { result.Add(s[start..i]); }
                start = i + 1;
                if (result.Count == maxSplits) break;
            }
            i++;
        }
        if (start < s.Length) result.Add(s[start..]);
        return result;
    }

    /// 只去掉空格和制表符（Swift 的 `.whitespaces`）。
    public static string TrimWs(this string s) => s.Trim(' ', '\t');

    /// NSString.lastPathComponent
    public static string LastPathComponent(string p)
    {
        var t = p.TrimEnd('/');
        if (t.Length == 0) return p.Length > 0 ? "/" : "";
        int i = t.LastIndexOf('/');
        return i < 0 ? t : t[(i + 1)..];
    }

    public static string DeletingPathExtension(string name)
    {
        int i = name.LastIndexOf('.');
        return i > 0 ? name[..i] : name;
    }

    /// 按行切分（保留空行），等同 `components(separatedBy: "\n")`。
    public static string[] Lines(string s) => s.Split('\n');

    public static string Fmt(double v, string format) => v.ToString(format, Inv);

    public static string Prefix(this string s, int n) => s.Length <= n ? s : s[..n];
}

public static class Format
{
    /// 3725 -> "1:02:05"，超过一天 -> "2d 03:10"
    public static string Duration(double t)
    {
        long s = Math.Max(0, (long)t);
        long d = s / 86400, h = s % 86400 / 3600, m = s % 3600 / 60, sec = s % 60;
        if (d > 0) return $"{d}d {h:00}:{m:00}";
        if (h > 0) return $"{h}:{m:00}:{sec:00}";
        return $"{m}:{sec:00}";
    }

    /// 简短时长："42m" "3.5h" "2d"
    public static string ShortDuration(double t)
    {
        var s = Math.Max(0, t);
        if (s < 60) return $"{(int)s}s";
        if (s < 3600) return $"{(int)(s / 60)}m";
        if (s < 86400) return Text.Fmt(s / 3600, s < 36000 ? "0.0" : "0") + "h";
        return Text.Fmt(s / 86400, "0") + "d";
    }

    public static string Relative(DateTime date, DateTime? now = null)
    {
        var s = ((now ?? DateTime.Now) - date).TotalSeconds;
        if (s < 5) return L("刚刚", "just now");
        if (s < 60) return L($"{(int)s}秒前", $"{(int)s}s ago");
        if (s < 3600) return L($"{(int)(s / 60)}分钟前", $"{(int)(s / 60)}m ago");
        if (s < 86400) return L($"{(int)(s / 3600)}小时前", $"{(int)(s / 3600)}h ago");
        return L($"{(int)(s / 86400)}天前", $"{(int)(s / 86400)}d ago");
    }

    public static string Bytes(double b)
    {
        var gb = b / 1_073_741_824;
        if (gb >= 100) return Text.Fmt(gb, "0") + "G";
        if (gb >= 1) return Text.Fmt(gb, "0.0") + "G";
        return Text.Fmt(b / 1_048_576, "0") + "M";
    }

    public static string Percent(double v) => $"{(int)Math.Round(v * 100, MidpointRounding.AwayFromZero)}%";

    public static string Time(DateTime d) => d.ToString("HH:mm", CultureInfo.InvariantCulture);
}
