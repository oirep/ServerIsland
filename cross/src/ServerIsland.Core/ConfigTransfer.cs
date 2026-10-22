using System.Text.Json;
using System.Text.Json.Nodes;

namespace ServerIsland.Core;

/// 设置的导入导出（与 Swift 版 ConfigTransfer.swift 对应）：换电脑、在 Mac 和 Windows / Linux 之间迁移。
/// 导出的就是 config.json 本身（两个版本格式相同）；密码只在系统凭据库里，不会导出。
public static class ConfigTransfer
{
    public enum Mode { Replace, AddHosts }

    public sealed class NotSettingsException() : Exception("not a ServerIsland settings file");

    public static string ExportJson(AppSettings settings) => JsonSerializer.Serialize(settings, Json.Options);

    public static string DefaultFileName(DateTime? date = null) => $"ServerIsland-settings-{date ?? DateTime.Now:yyyy-MM-dd}.json";

    /// 读导入的文件。随便一个 JSON 也能解出全是默认值的设置，所以要求顶层有 hosts。
    /// 读不出来时抛 JsonException，不是设置文件时抛 NotSettingsException。
    public static AppSettings Read(string json)
    {
        if (JsonNode.Parse(json) is not JsonObject obj) throw new JsonException("not an object");
        if (obj["hosts"] is not JsonArray) throw new NotSettingsException();
        return JsonSerializer.Deserialize<AppSettings>(json, Json.Options) ?? throw new JsonException("empty");
    }

    /// 导入里有、当前没有的服务器（按 ID，或者连接目标相同）。
    public static List<HostConfig> NewHosts(AppSettings current, AppSettings imported)
    {
        static string Key(HostConfig h) => string.Join("|", h.Alias, h.HostName, h.User, h.Port ?? 0);
        var ids = current.Hosts.Select(h => h.Id).ToHashSet();
        var keys = current.Hosts.Select(Key).ToHashSet();
        return imported.Hosts.Where(h => !ids.Contains(h.Id) && !keys.Contains(Key(h))).ToList();
    }

    /// 合并结果。替换：用导入的全部设置，只保留这台电脑自己的东西（显示器、显示方式、SSH 实现、小章鱼位置、提醒过的版本）；
    /// 只添加服务器：其余设置不动。两种方式都去掉指向不存在的服务器的关注和跳板机。
    public static AppSettings Apply(AppSettings current, AppSettings imported, Mode mode)
    {
        AppSettings outS;
        if (mode == Mode.Replace)
        {
            outS = imported.Clone();
            outS.IslandScreen = current.IslandScreen;
            outS.DisplayMode = current.DisplayMode;
            outS.SshBackend = current.SshBackend;
            outS.PetX = current.PetX;
            outS.PetY = current.PetY;
            outS.NotifiedUpdateVersion = current.NotifiedUpdateVersion;
        }
        else
        {
            outS = current.Clone();
            outS.Hosts.AddRange(NewHosts(current, imported).Select(h => h.Clone()));
        }
        var ids = outS.Hosts.Select(h => h.Id).ToHashSet();
        foreach (var h in outS.Hosts)
            if (h.JumpHostID is { } j && !ids.Contains(j)) h.JumpHostID = null;
        outS.StarredJobs.RemoveAll(s => !ids.Contains(s.HostID));
        return outS;
    }

    /// 替换之前把当前设置复制一份（config.before-import-<时间>.json），弄错了还能找回来。
    public static string? BackupCurrent(AppSettings settings, string? dir = null)
    {
        try
        {
            dir ??= AppPaths.ConfigDirectory;
            Directory.CreateDirectory(dir);
            var path = Path.Combine(dir, $"config.before-import-{DateTime.Now:yyyyMMdd-HHmmss}.json");
            File.WriteAllText(path, ExportJson(settings));
            return path;
        }
        catch { return null; }
    }
}
