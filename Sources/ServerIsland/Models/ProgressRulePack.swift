import Foundation

/// 文件识别和 Action 日志识别共用可移植 JSON 包；导入只更新配置，不运行任何命令。
struct ProgressRulePack: Codable {
    var format = "serverisland.progress-rules"
    var version = 1
    var rules: [ProgressRule]

    static func decode(_ data: Data) throws -> ProgressRulePack {
        guard data.count <= 1024 * 1024 else { throw Failure(L("规则文件不能超过 1 MB", "Rules file exceeds 1 MB")) }
        let decoder = JSONDecoder()
        let pack: ProgressRulePack
        if let array = try? decoder.decode([ProgressRule].self, from: data) { pack = ProgressRulePack(rules: array) }
        else { pack = try decoder.decode(ProgressRulePack.self, from: data) }
        guard pack.format == "serverisland.progress-rules", pack.version == 1,
              pack.rules.count <= 200, Set(pack.rules.map(\.id)).count == pack.rules.count else {
            throw Failure(L("规则包格式、版本或标识不合法", "Invalid rule format, version or duplicate IDs"))
        }
        for rule in pack.rules where rule.enabled {
            if let problem = rule.problem { throw Failure(rule.name + ": " + problem) }
        }
        return pack
    }
    func merging(into existing: [ProgressRule]) -> [ProgressRule] {
        let ids = Set(rules.map(\.id))
        return existing.filter { !ids.contains($0.id) } + rules
    }
    func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
    struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
