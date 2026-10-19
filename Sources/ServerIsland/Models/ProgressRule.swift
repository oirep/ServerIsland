import Foundation

/// 用户自定义的进度识别规则：任务的工作目录里有某个文件，就从这个文件里取"当前值"和"目标值"。
/// 保存在全局设置里，对所有服务器生效。规则在内置识别（NEP / GPUMD / VASP / LAMMPS）之前检查。
/// 任何一步对不上（文件没有、数字取不到、当前值超过目标值）都当作没识别到，不显示进度。
struct ProgressRule: Codable, Equatable, Identifiable {
    enum Source: String, Codable, CaseIterable { case file, actionLog }
    enum LogMode: String, Codable, CaseIterable { case numbered, stages }
    struct LogStage: Codable, Equatable, Identifiable {
        var id = UUID()
        var name = ""
        var pattern = ""
        init(name: String = "", pattern: String = "") { self.name = name; self.pattern = pattern }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
            name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
            pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        }
    }
    var source: Source = .file
    var logMode: LogMode = .numbered
    var activationPattern = ""
    var currentGroup = 1
    var totalGroup = 2
    var labelGroup = 3
    var stages: [LogStage] = []
    enum Match: String, Codable, CaseIterable, Identifiable {
        /// 关键字后面的数字，比如 `epoch` 匹配 "Epoch 37/100"、"epoch: 37"。
        case keyword
        /// 正则：第 1 个捕获组是当前值，第 2 个（可选）是目标值。
        case regex
        var id: String { rawValue }
        var label: String {
            switch self {
            case .keyword: return L("关键字", "Keyword")
            case .regex: return L("正则", "Regex")
            }
        }
    }

    var id = UUID()
    var enabled = true
    /// 显示名称，比如"PyTorch 训练"。
    var name = ""
    /// 工作目录里的文件名，可以用 * ? 通配（取最新的一个）。
    var file = ""
    var match: Match = .keyword
    /// 关键字或正则。
    var pattern = ""
    /// 固定的目标值（为空且没有从文件里取到时，只显示当前值）。
    var total = ""
    /// 从另一个文件里取目标值：文件名 + 关键字（取第一次出现时后面的数字），比如 `nep.in` + `generation`。
    var totalFile = ""
    var totalKeyword = ""
    /// 正常结束的标记文字（可选）：文件末尾出现它就算完成；进程结束时没有它就算提前结束。
    var doneMarker = ""
    /// 单位，比如"epoch"、"步"。
    var unit = ""

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        source = try c.decodeIfPresent(Source.self, forKey: .source) ?? .file
        logMode = try c.decodeIfPresent(LogMode.self, forKey: .logMode) ?? .numbered
        activationPattern = try c.decodeIfPresent(String.self, forKey: .activationPattern) ?? ""
        currentGroup = try c.decodeIfPresent(Int.self, forKey: .currentGroup) ?? 1
        totalGroup = try c.decodeIfPresent(Int.self, forKey: .totalGroup) ?? 2
        labelGroup = try c.decodeIfPresent(Int.self, forKey: .labelGroup) ?? 3
        stages = try c.decodeIfPresent([LogStage].self, forKey: .stages) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        file = try c.decodeIfPresent(String.self, forKey: .file) ?? ""
        match = try c.decodeIfPresent(Match.self, forKey: .match) ?? .keyword
        pattern = try c.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        total = try c.decodeIfPresent(String.self, forKey: .total) ?? ""
        totalFile = try c.decodeIfPresent(String.self, forKey: .totalFile) ?? ""
        totalKeyword = try c.decodeIfPresent(String.self, forKey: .totalKeyword) ?? ""
        doneMarker = try c.decodeIfPresent(String.self, forKey: .doneMarker) ?? ""
        unit = try c.decodeIfPresent(String.self, forKey: .unit) ?? ""
    }

    /// 文件名只允许常见字符（会原样放进远端 shell 做通配）。
    static func isSafeFileName(_ s: String) -> Bool {
        !s.isEmpty && s.count <= 120 && !s.hasPrefix("/") && !s.contains("..")
            && s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-*?/+".contains($0)) }
    }

    /// 规则是否完整可用；不可用时返回原因（设置页里显示）。
    var problem: String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return L("还没有填名称", "Name is empty") }
        if source == .actionLog {
            if !activationPattern.isEmpty, !Self.validLogRegex(activationPattern) {
                return L("激活正则无效", "Invalid activation regex")
            }
            if logMode == .stages {
                if stages.isEmpty || stages.count > 100 { return L("需要 1–100 个阶段", "Specify 1–100 stages") }
                if stages.contains(where: { $0.name.isEmpty || !Self.validLogRegex($0.pattern) }) {
                    return L("阶段名称或正则无效", "Invalid stage name or regex")
                }
            } else {
                guard Self.validLogRegex(pattern), let regex = try? NSRegularExpression(pattern: pattern) else {
                    return L("日志正则无效", "Invalid log regex")
                }
                let count = regex.numberOfCaptureGroups
                if currentGroup < 1 || currentGroup > count || labelGroup < 0 || labelGroup > count {
                    return L("阶段编号或名称捕获组超出范围", "Stage or label capture group is out of range")
                }
                if total.isEmpty {
                    if totalGroup < 1 || totalGroup > count { return L("请设置总数捕获组或固定总阶段数", "Set a total capture group or fixed total") }
                } else if !(1...1000).contains(Int(total) ?? 0) {
                    return L("固定总阶段数需要为 1–1000 的整数", "Fixed total must be an integer from 1 to 1000")
                }
            }
            return nil
        }
        if !Self.isSafeFileName(file) { return L("文件名为空或含有不支持的字符", "File name is empty or has unsupported characters") }
        if pattern.isEmpty { return match == .keyword ? L("还没有填关键字", "Keyword is empty") : L("还没有填正则", "Regex is empty") }
        if match == .regex {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return L("正则写法有误", "Invalid regex") }
            if re.numberOfCaptureGroups < 1 { return L("正则里需要至少一个捕获组 ( )，代表当前值", "The regex needs a capture group ( ) for the current value") }
        }
        if !total.isEmpty, Double(total) == nil { return L("目标值需要是数字", "Target must be a number") }
        if !totalFile.isEmpty, !Self.isSafeFileName(totalFile) { return L("目标值文件名含有不支持的字符", "Target file name has unsupported characters") }
        if !totalFile.isEmpty, totalKeyword.isEmpty { return L("从文件取目标值时需要填关键字", "A keyword is needed to read the target from a file") }
        return nil
    }

    var isUsable: Bool { source == .file && enabled && problem == nil }
    var isLogUsable: Bool { source == .actionLog && enabled && problem == nil }
    static func validLogRegex(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 1000 && (try? NSRegularExpression(pattern: value)) != nil
    }

    /// 当前生效的规则（由 ConfigStore 在启动和修改设置时更新，生成远端脚本时读取）。
    static var active: [ProgressRule] = []

    // MARK: - 从文件内容里取数字

    /// 在若干行里（从最后一行往前）找当前值和目标值。
    func extract(from lines: [String]) -> (current: Double, total: Double?)? {
        switch match {
        case .keyword:
            let re = Self.keywordRegex(pattern)
            for line in lines.reversed() {
                if let m = Self.firstMatch(re, line) {
                    return (m[0]!, m.count > 1 ? m[1] : nil)
                }
            }
        case .regex:
            guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
            for line in lines.reversed() {
                if let m = Self.firstMatch(re, line), let c = m[0] {
                    return (c, m.count > 1 ? m[1] : nil)
                }
            }
        }
        return nil
    }

    /// 关键字后面的数字：允许中间有空格、冒号、等号、#；后面可以跟 "/ 目标值" 或 "of 目标值"。不区分大小写。
    static func keywordRegex(_ kw: String) -> NSRegularExpression? {
        let k = NSRegularExpression.escapedPattern(for: kw)
        return try? NSRegularExpression(
            pattern: k + #"\s*[:=#]?\s*(-?\d+(?:\.\d+)?)(?:\s*(?:/|of)\s*(\d+(?:\.\d+)?))?"#,
            options: [.caseInsensitive])
    }

    /// 目标值文件里"关键字后面的数字"（第一次出现）。
    static func number(after kw: String, in line: String) -> Double? {
        firstMatch(keywordRegex(kw), line)?.first ?? nil
    }

    private static func firstMatch(_ re: NSRegularExpression?, _ line: String) -> [Double?]? {
        guard let re, let m = re.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { return nil }
        let ns = line as NSString
        var out: [Double?] = []
        for i in 1..<max(m.numberOfRanges, 2) {
            let r = i < m.numberOfRanges ? m.range(at: i) : NSRange(location: NSNotFound, length: 0)
            out.append(r.location == NSNotFound ? nil : Double(ns.substring(with: r).replacingOccurrences(of: ",", with: "")))
        }
        guard out.first.map({ $0 != nil }) == true else { return nil }
        return out
    }
}
