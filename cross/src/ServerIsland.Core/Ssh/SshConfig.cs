using System.Text.RegularExpressions;

namespace ServerIsland.Core.Ssh;

/// `~/.ssh/config` 里的一个具体主机（不含通配符），用于"添加服务器"列表。
public sealed record SshConfigEntry(string Alias, string? HostName, string? User, string? Port, string? ProxyJump)
{
    public string Summary
    {
        get
        {
            var s = "";
            if (User != null) s += User + "@";
            s += HostName ?? Alias;
            if (Port != null && Port != "22") s += ":" + Port;
            if (ProxyJump != null) s += "  via " + ProxyJump;
            return s;
        }
    }
}

/// 解析后的连接参数（内置 SSH 用；系统 ssh 自己读配置）。
public sealed class ResolvedHost
{
    public string Alias = "";
    public string HostName = "";
    public string User = "";
    public int Port = 22;
    public List<string> IdentityFiles = [];
    public string? ProxyJump;
    public string? ProxyCommand;
    public string StrictHostKeyChecking = "ask";
    public string? UserKnownHostsFile;
    public string? HostKeyAlias;
    public int? ConnectTimeout;
}

/// `~/.ssh/config` 的轻量解析：列出主机；为内置 SSH 解析 HostName / User / Port / IdentityFile / ProxyJump 等。
/// 按 OpenSSH 的规则，同一个参数取第一次出现的值；Match 块跳过。
public static class SshConfig
{
    public static string DefaultPath => Path.Combine(AppPaths.SshDirectory, "config");

    sealed record Block(List<string> Patterns, List<(string Key, string Value)> Options);

    static List<Block> LoadBlocks(string path)
    {
        var blocks = new List<Block> { new(["*"], []) };   // Host 之前的全局参数
        var visited = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        // 开发 / 测试用：先读一份额外配置（比如测试用的 known_hosts），和系统 ssh 的私有配置一致，不碰用户的 ~/.ssh。
        if (path == DefaultPath && Environment.GetEnvironmentVariable("SERVERISLAND_SSH_EXTRA_CONFIG") is { Length: > 0 } extra)
        {
            Parse(extra, blocks, visited);
            blocks.Add(new Block(["*"], []));
        }
        Parse(path, blocks, visited);
        return blocks;
    }

    static void Parse(string file, List<Block> blocks, HashSet<string> visited)
    {
        var path = ExpandTilde(file);
        if (!visited.Add(path) || !File.Exists(path)) return;
        string text;
        try { text = File.ReadAllText(path); } catch { return; }
        foreach (var rawLine in text.Split('\n'))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var (key, value) = SplitKeyValue(line);
            switch (key.ToLowerInvariant())
            {
                case "host":
                    blocks.Add(new Block(value.Split([' ', '\t'], StringSplitOptions.RemoveEmptyEntries).ToList(), []));
                    break;
                case "match":
                    blocks.Add(new Block([], []));   // 不支持 Match：这一块的参数不生效
                    break;
                case "include":
                    foreach (var pattern in value.Split(' ', StringSplitOptions.RemoveEmptyEntries))
                    {
                        var p = ExpandTilde(pattern);
                        if (!Path.IsPathRooted(p)) p = Path.Combine(AppPaths.SshDirectory, p);
                        foreach (var f in Glob(p)) Parse(f, blocks, visited);
                    }
                    break;
                default:
                    blocks[^1].Options.Add((key.ToLowerInvariant(), value));
                    break;
            }
        }
    }

    /// 列出具体主机（不含通配符），和 Swift 版一样只取 HostName / User / Port / ProxyJump 做摘要。
    public static List<SshConfigEntry> Load(string? path = null)
    {
        var blocks = LoadBlocks(path ?? DefaultPath);
        var seen = new HashSet<string>();
        var list = new List<SshConfigEntry>();
        foreach (var b in blocks.Skip(1))
        {
            foreach (var alias in b.Patterns)
            {
                if (alias.Contains('*') || alias.Contains('?') || alias.StartsWith('!') || !seen.Add(alias)) continue;
                string? Get(string k) => b.Options.FirstOrDefault(o => o.Key == k).Value;
                list.Add(new SshConfigEntry(alias, Get("hostname"), Get("user"), Get("port"), Get("proxyjump")));
            }
        }
        return list;
    }

    /// 按 OpenSSH 规则解析一个目标（别名、host、user@host、host:port 都可以）。
    public static ResolvedHost Resolve(string target, string? path = null)
    {
        string? userFromTarget = null;
        int? portFromTarget = null;
        var name = target.Trim();
        int at = name.LastIndexOf('@');
        if (at > 0) { userFromTarget = name[..at]; name = name[(at + 1)..]; }
        // host:port（不处理 IPv6 的方括号以外的冒号）
        if (name.StartsWith('[') && name.Contains("]:"))
        {
            var close = name.IndexOf("]:", StringComparison.Ordinal);
            portFromTarget = Text.Int(name[(close + 2)..]);
            name = name[1..close];
        }
        else if (name.Count(c => c == ':') == 1 && Text.Int(name[(name.IndexOf(':') + 1)..]) is { } p)
        {
            portFromTarget = p;
            name = name[..name.IndexOf(':')];
        }

        var values = new Dictionary<string, string>();
        var identities = new List<string>();
        foreach (var b in LoadBlocks(path ?? DefaultPath))
        {
            if (!Matches(b.Patterns, name)) continue;
            foreach (var (k, v) in b.Options)
            {
                if (k == "identityfile") identities.Add(v);
                else values.TryAdd(k, v);
            }
        }

        var r = new ResolvedHost { Alias = name };
        r.HostName = values.TryGetValue("hostname", out var hn) ? hn.Replace("%h", name) : name;
        r.User = userFromTarget ?? (values.TryGetValue("user", out var u) ? u : Environment.UserName);
        r.Port = portFromTarget ?? (values.TryGetValue("port", out var port) && Text.Int(port) is { } pp ? pp : 22);
        if (values.TryGetValue("proxyjump", out var pj) && !pj.Equals("none", StringComparison.OrdinalIgnoreCase)) r.ProxyJump = pj;
        if (values.TryGetValue("proxycommand", out var pc) && !pc.Equals("none", StringComparison.OrdinalIgnoreCase)) r.ProxyCommand = pc;
        if (values.TryGetValue("stricthostkeychecking", out var sh)) r.StrictHostKeyChecking = sh.ToLowerInvariant();
        if (values.TryGetValue("userknownhostsfile", out var kh)) r.UserKnownHostsFile = ExpandTilde(kh.Split(' ')[0]);
        if (values.TryGetValue("hostkeyalias", out var ha)) r.HostKeyAlias = ha;
        if (values.TryGetValue("connecttimeout", out var ct)) r.ConnectTimeout = Text.Int(ct);
        r.IdentityFiles = identities.Select(i => ExpandTokens(i, r)).ToList();
        return r;
    }

    static string ExpandTokens(string path, ResolvedHost r)
    {
        var p = path.Trim('"')
            .Replace("%d", AppPaths.Home).Replace("%u", Environment.UserName)
            .Replace("%r", r.User).Replace("%h", r.HostName).Replace("%%", "%");
        return ExpandTilde(p);
    }

    /// Host 行的模式匹配：支持 * ? 和 ! 取反。
    static bool Matches(List<string> patterns, string host)
    {
        bool any = false;
        foreach (var p in patterns)
        {
            bool negate = p.StartsWith('!');
            var pat = negate ? p[1..] : p;
            var re = "^" + Regex.Escape(pat).Replace(@"\*", ".*").Replace(@"\?", ".") + "$";
            if (Regex.IsMatch(host, re, RegexOptions.IgnoreCase))
            {
                if (negate) return false;
                any = true;
            }
        }
        return any;
    }

    static (string, string) SplitKeyValue(string line)
    {
        // 支持 "Key Value" 和 "Key=Value"
        int idx = line.IndexOfAny([' ', '\t', '=']);
        if (idx < 0) return (line, "");
        var key = line[..idx];
        var rest = line[idx..].TrimStart(' ', '\t', '=');
        if (rest.Length >= 2 && rest.StartsWith('"') && rest.EndsWith('"')) rest = rest[1..^1];
        return (key, rest);
    }

    public static string ExpandTilde(string p) =>
        p == "~" ? AppPaths.Home : p.StartsWith("~/") || p.StartsWith("~\\") ? Path.Combine(AppPaths.Home, p[2..]) : p;

    static IEnumerable<string> Glob(string pattern)
    {
        var dir = Path.GetDirectoryName(pattern);
        var file = Path.GetFileName(pattern);
        if (string.IsNullOrEmpty(dir) || !Directory.Exists(dir)) return [];
        if (!file.Contains('*') && !file.Contains('?')) return File.Exists(pattern) ? [pattern] : [];
        try { return Directory.GetFiles(dir, file).OrderBy(f => f, StringComparer.Ordinal); } catch { return []; }
    }
}
