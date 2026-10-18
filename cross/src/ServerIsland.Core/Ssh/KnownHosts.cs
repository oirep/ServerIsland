using System.Security.Cryptography;
using System.Text;

namespace ServerIsland.Core.Ssh;

/// 读写 OpenSSH 格式的 known_hosts（支持明文和 |1| 哈希条目）。内置 SSH 用它校验主机指纹。
public static class KnownHosts
{
    public enum Verdict { Match, Unknown, Mismatch }

    public static string DefaultPath => Path.Combine(AppPaths.SshDirectory, "known_hosts");

    /// known_hosts 里的主机写法：端口 22 时就是主机名，否则是 [host]:port。
    public static string HostKey(string host, int port) => port == 22 ? host : $"[{host}]:{port}";

    public static Verdict Check(string host, int port, string keyType, byte[] keyBlob, string? path = null)
    {
        var file = path ?? DefaultPath;
        if (file == "/dev/null" || !File.Exists(file)) return Verdict.Unknown;
        var name = HostKey(host, port);
        var b64 = Convert.ToBase64String(keyBlob);
        bool sawSameType = false;
        string[] lines;
        try { lines = File.ReadAllLines(file); } catch { return Verdict.Unknown; }
        foreach (var raw in lines)
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var parts = line.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries);
            int i = 0;
            if (parts[0].StartsWith('@'))
            {
                if (parts[0] == "@revoked") continue;   // 不处理 CA / 吊销条目
                i = 1;
            }
            if (parts.Length < i + 3) continue;
            if (!HostMatches(parts[i], name)) continue;
            if (parts[i + 2] == b64) return Verdict.Match;
            if (Norm(parts[i + 1]) == Norm(keyType)) sawSameType = true;
        }
        return sawSameType ? Verdict.Mismatch : Verdict.Unknown;
    }

    /// rsa-sha2-256 / rsa-sha2-512 是 ssh-rsa 密钥的签名算法，known_hosts 里记作 ssh-rsa。
    static string Norm(string t) => t.StartsWith("rsa-sha2", StringComparison.Ordinal) ? "ssh-rsa" : t;

    static bool HostMatches(string field, string name)
    {
        if (field.StartsWith("|1|"))
        {
            var p = field.Split('|');
            if (p.Length < 4) return false;
            try
            {
                using var h = new HMACSHA1(Convert.FromBase64String(p[2]));
                return Convert.ToBase64String(h.ComputeHash(Encoding.UTF8.GetBytes(name))) == p[3];
            }
            catch { return false; }
        }
        bool any = false;
        foreach (var pat in field.Split(','))
        {
            bool neg = pat.StartsWith('!');
            var pp = neg ? pat[1..] : pat;
            var re = "^" + System.Text.RegularExpressions.Regex.Escape(pp).Replace(@"\*", ".*").Replace(@"\?", ".") + "$";
            if (System.Text.RegularExpressions.Regex.IsMatch(name, re, System.Text.RegularExpressions.RegexOptions.IgnoreCase))
            {
                if (neg) return false;
                any = true;
            }
        }
        return any;
    }

    public static void Add(string host, int port, string keyType, byte[] keyBlob, string? path = null)
    {
        var file = path ?? DefaultPath;
        if (file == "/dev/null") return;
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        var prefix = File.Exists(file) && new FileInfo(file).Length > 0 && !File.ReadAllText(file).EndsWith('\n') ? "\n" : "";
        File.AppendAllText(file, $"{prefix}{HostKey(host, port)} {keyType} {Convert.ToBase64String(keyBlob)}\n");
    }

    public static string Fingerprint(byte[] keyBlob) =>
        "SHA256:" + Convert.ToBase64String(SHA256.HashData(keyBlob)).TrimEnd('=');
}
