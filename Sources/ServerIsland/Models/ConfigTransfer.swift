import Foundation

/// 设置的导入导出：换电脑、在 Mac 和 Windows / Linux 之间迁移。
/// 导出的就是 config.json 本身（两个版本格式相同）；密码只在系统钥匙串里，不会导出。
enum ConfigTransfer {
    enum Mode { case replace, addHosts }

    enum Failure: Error { case unreadable, notSettings }

    static func exportData(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(settings)
    }

    static func defaultFileName(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return "ServerIsland-settings-\(f.string(from: date)).json"
    }

    /// 读导入的文件。随便一个 JSON 也能解出全是默认值的设置，所以要求顶层有 hosts。
    static func read(_ data: Data) throws -> AppSettings {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.unreadable }
        guard obj["hosts"] is [Any] else { throw Failure.notSettings }
        do { return try JSONDecoder().decode(AppSettings.self, from: data) } catch { throw Failure.unreadable }
    }

    /// 导入里有、当前没有的服务器（按 ID，或者连接目标相同）。
    static func newHosts(current: AppSettings, imported: AppSettings) -> [HostConfig] {
        func key(_ h: HostConfig) -> String { [h.alias, h.hostName, h.user, "\(h.port ?? 0)"].joined(separator: "|") }
        let ids = Set(current.hosts.map(\.id)), keys = Set(current.hosts.map(key))
        return imported.hosts.filter { !ids.contains($0.id) && !keys.contains(key($0)) }
    }

    /// 合并结果。替换：用导入的全部设置，只保留这台电脑自己的显示器选择；只添加服务器：其余设置不动。
    /// 两种方式都去掉指向不存在的服务器的关注和跳板机。
    static func apply(current: AppSettings, imported: AppSettings, mode: Mode) -> AppSettings {
        var out: AppSettings
        switch mode {
        case .replace:
            out = imported
            out.islandScreen = current.islandScreen
        case .addHosts:
            out = current
            out.hosts += newHosts(current: current, imported: imported)
        }
        let ids = Set(out.hosts.map(\.id))
        for i in out.hosts.indices where out.hosts[i].jumpHostID.map({ !ids.contains($0) }) ?? false {
            out.hosts[i].jumpHostID = nil
        }
        out.starredJobs.removeAll { !ids.contains($0.hostID) }
        return out
    }

    /// 替换之前把当前的 config.json 复制一份（config.before-import-<时间>.json），弄错了还能找回来。
    static func backupCurrent(_ settings: AppSettings, to dir: URL) -> URL? {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appendingPathComponent("config.before-import-\(stamp.string(from: Date())).json")
        guard let data = try? exportData(settings) else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try? data.write(to: url, options: .atomic)) == nil ? nil : url
    }
}
