import Foundation

/// `~/.ssh/config` 里的一个具体主机（不含通配符）。
struct SSHConfigEntry: Identifiable, Hashable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: String?
    var proxyJump: String?

    var id: String { alias }

    var summary: String {
        var s = ""
        if let user { s += user + "@" }
        s += hostName ?? alias
        if let port, port != "22" { s += ":" + port }
        if let proxyJump { s += "  via " + proxyJump }
        return s
    }
}

/// 只做"列出主机"所需的轻量解析；真正连接时完全交给系统 ssh，
/// 所以 Match、Include 的复杂语义不影响连接行为。
enum SSHConfigParser {
    static var defaultPath: String { NSHomeDirectory() + "/.ssh/config" }

    static func load(path: String = defaultPath) -> [SSHConfigEntry] {
        var visited = Set<String>()
        var entries: [SSHConfigEntry] = []
        parse(file: path, into: &entries, visited: &visited)
        var seen = Set<String>()
        return entries.filter { seen.insert($0.alias).inserted }
    }

    private static func parse(file: String, into entries: inout [SSHConfigEntry], visited: inout Set<String>) {
        let path = (file as NSString).expandingTildeInPath
        guard visited.insert(path).inserted,
              let text = try? String(contentsOfFile: path, encoding: .utf8) else { return }

        var current: [Int] = []   // 当前 Host 块对应的 entries 下标
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let (key, value) = splitKeyValue(line)
            switch key.lowercased() {
            case "host":
                current = []
                for pattern in value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init) {
                    if pattern.contains("*") || pattern.contains("?") || pattern.hasPrefix("!") { continue }
                    entries.append(SSHConfigEntry(alias: pattern))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "include":
                for pattern in value.split(separator: " ").map(String.init) {
                    var p = (pattern as NSString).expandingTildeInPath
                    if !p.hasPrefix("/") { p = NSHomeDirectory() + "/.ssh/" + p }
                    for f in glob(p) { parse(file: f, into: &entries, visited: &visited) }
                }
            case "hostname":
                for i in current where entries[i].hostName == nil { entries[i].hostName = value }
            case "user":
                for i in current where entries[i].user == nil { entries[i].user = value }
            case "port":
                for i in current where entries[i].port == nil { entries[i].port = value }
            case "proxyjump":
                for i in current where entries[i].proxyJump == nil { entries[i].proxyJump = value }
            default:
                break
            }
        }
    }

    private static func splitKeyValue(_ line: String) -> (String, String) {
        // 支持 "Key Value" 和 "Key=Value"
        if let idx = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) {
            let key = String(line[..<idx])
            var rest = line[idx...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" })
            if rest.hasPrefix("\"") && rest.hasSuffix("\"") && rest.count >= 2 {
                rest = rest.dropFirst().dropLast()
            }
            return (key, String(rest))
        }
        return (line, "")
    }

    private static func glob(_ pattern: String) -> [String] {
        var gt = glob_t()
        defer { globfree(&gt) }
        guard Darwin.glob(pattern, 0, nil, &gt) == 0 else { return [] }
        return (0..<Int(gt.gl_pathc)).compactMap { gt.gl_pathv[$0].flatMap { String(cString: $0) } }
    }
}
