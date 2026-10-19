import Foundation

/// Action 是用户明确配置的命令；保存设置不会执行，只有点击对应按钮才会启动。
struct HostAction: Codable, Equatable, Identifiable {
    enum Target: String, Codable, CaseIterable, Identifiable {
        case local, remote
        var id: String { rawValue }
        var label: String { self == .local ? L("本机", "Local") : L("服务器", "Server") }
    }
    var id = UUID()
    var name = ""
    var command = ""
    var target: Target = .remote
    var enabled = true
    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    init(name: String = "", command: String = "", target: Target = .remote) {
        self.name = name; self.command = command; self.target = target
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        command = try c.decodeIfPresent(String.self, forKey: .command) ?? ""
        target = try c.decodeIfPresent(Target.self, forKey: .target) ?? .remote
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }
}
