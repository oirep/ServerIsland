import Foundation

/// Slurm 分区的空闲资源（按需查询，不参与轮询）。
struct PartitionStat: Identifiable, Equatable {
    var name: String
    var isDefault = false
    var available = true
    var timeLimit = ""
    var nodes = 0, idleNodes = 0, mixNodes = 0, allocNodes = 0, downNodes = 0
    var cpuIdle = 0, cpuTotal = 0
    /// 加速卡（GPU，或曙光的 DCU 等）合在一起算；gpuKinds 记下出现过的种类，界面按它显示"GPU" / "DCU"。
    var gpuIdle = 0, gpuTotal = 0
    var gpuModels: Set<String> = []
    var gpuKinds: Set<String> = []

    var id: String { name }

    /// 加速卡的名字：只有一种时就是它（DCU），混在一起时用"/"连起来，没有时是 GPU。
    var gpuLabel: String { Self.label(gpuKinds) }

    static func label(_ kinds: Set<String>) -> String {
        kinds.isEmpty ? "GPU" : kinds.map { $0.uppercased() }.sorted().joined(separator: "/")
    }
}

enum Partitions {
    static func script(host: HostConfig) -> String {
        var s = ""
        if !host.commands.preamble.isEmpty { s += host.commands.preamble + "\n" }
        let m = RemoteScript.marker
        s += """
        printf '\(m)SEC summary\\n'; sinfo -h -o '%P|%a|%l' 2>&1; printf '\(m)RC %s\\n' "$?"
        printf '\(m)SEC nodes\\n'; sinfo -N -h -O 'NodeList:80,Partition:60,StateCompact:20,CPUsState:30,Gres:200,GresUsed:240' 2>&1; printf '\(m)RC %s\\n' "$?"

        """
        return s
    }

    /// 认作加速卡的 Gres 名字：NVIDIA / AMD 的 gpu，曙光（海光）的 dcu，昇腾的 npu，寒武纪的 mlu。
    private static let gpuRegex = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])(gpu|dcu|npu|mlu)(?::([^:(,\s]+))?:(\d+)"#)

    /// "gpu:V100-SXM2:4(S:0-1)" -> (4, ["V100-SXM2"], ["gpu"])；"gpu:a100:2(IDX:0-1),gpu:v100:1" 会相加；
    /// 曙光的 "dcu:Hygon:4(S:0-3)" -> (4, ["Hygon"], ["dcu"])。数量为 0 的种类（GresUsed 里的 "dcu:0,gpu:0"）不算。
    static func gpuCount(_ s: String) -> (count: Int, models: Set<String>, kinds: Set<String>) {
        guard s != "(null)" else { return (0, [], []) }
        var n = 0
        var models: Set<String> = [], kinds: Set<String> = []
        let ns = s as NSString
        for m in gpuRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let k = Int(ns.substring(with: m.range(at: 3))) ?? 0
            guard k > 0 else { continue }
            n += k
            kinds.insert(ns.substring(with: m.range(at: 1)))
            if m.range(at: 2).location != NSNotFound { models.insert(ns.substring(with: m.range(at: 2))) }
        }
        return (n, models, kinds)
    }

    static func parse(_ parsed: RemoteScript.Parsed) -> [PartitionStat]? {
        guard let nodes = parsed.sections["nodes"], nodes.exitCode == 0 else { return nil }
        var map: [String: PartitionStat] = [:]
        var order: [String] = []

        func key(_ raw: String) -> (String, Bool) {
            raw.hasSuffix("*") ? (String(raw.dropLast()), true) : (raw, false)
        }

        if let sum = parsed.sections["summary"], sum.exitCode == 0 {
            for line in sum.lines {
                let f = line.components(separatedBy: "|")
                guard f.count >= 3, !f[0].isEmpty else { continue }
                let (name, def) = key(f[0])
                var p = map[name] ?? PartitionStat(name: name)
                p.isDefault = def
                p.available = f[1] == "up"
                p.timeLimit = f[2]
                if map[name] == nil { order.append(name) }
                map[name] = p
            }
        }

        for line in nodes.lines {
            let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard f.count >= 4 else { continue }
            let (name, def) = key(f[1])
            var p = map[name] ?? PartitionStat(name: name)
            if map[name] == nil { order.append(name) }
            if def { p.isDefault = true }
            let state = f[2].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "*~#!%$@^-+"))
            let usable = !(state.hasPrefix("down") || state.hasPrefix("drain") || state.hasPrefix("drng")
                           || state.hasPrefix("fail") || state.hasPrefix("maint") || state.hasPrefix("unk")
                           || state.hasPrefix("boot") || state.hasPrefix("powered") || state.hasPrefix("inval"))
            p.nodes += 1
            if !usable { p.downNodes += 1 }
            else if state.hasPrefix("idle") { p.idleNodes += 1 }
            else if state.hasPrefix("mix") { p.mixNodes += 1 }
            else { p.allocNodes += 1 }

            let cpu = f[3].split(separator: "/").compactMap { Int($0) }   // A/I/O/T
            if cpu.count == 4 {
                p.cpuTotal += cpu[3]
                if usable { p.cpuIdle += cpu[1] }
            }
            if f.count >= 5 {
                let (total, models, kinds) = gpuCount(f[4])
                let used = f.count >= 6 ? gpuCount(f[5]).count : 0
                p.gpuTotal += total
                p.gpuModels.formUnion(models)
                p.gpuKinds.formUnion(kinds)
                if usable { p.gpuIdle += max(0, total - used) }
            }
            map[name] = p
        }
        return order.compactMap { map[$0] }
            .sorted { ($0.gpuIdle, $0.cpuIdle) > ($1.gpuIdle, $1.cpuIdle) }
    }
}

extension MonitorEngine {
    /// 查询分区资源；60 秒内重复打开直接用缓存。
    func fetchPartitions(host: HostConfig, force: Bool = false) async -> (stats: [PartitionStat]?, at: Date, error: String?) {
        if !force, let c = partitionCache[host.id], Date().timeIntervalSince(c.at) < 60 {
            return (c.stats, c.at, nil)
        }
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: Partitions.script(host: host), timeout: 25)
        if let problem = SSHRunner.classify(r, host: host) {
            switch problem {
            case .needsLogin(let m), .error(let m): return (nil, Date(), m)
            default: break
            }
        }
        let parsed = RemoteScript.parse(r.stdout)
        guard let stats = Partitions.parse(parsed) else {
            let msg = parsed.sections["nodes"]?.lines.last { !$0.isEmpty } ?? L("sinfo 不可用", "sinfo unavailable")
            return (nil, Date(), msg)
        }
        partitionCache[host.id] = (stats, Date())
        return (stats, Date(), nil)
    }
}
