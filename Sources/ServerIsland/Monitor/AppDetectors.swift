import Foundation

/// 计算软件的进度识别（NEP / GPUMD 参考 GPUMDkit Web Console 的判断逻辑；另有 VASP、LAMMPS 和用户自定义规则）。
/// 原则：任何一处和预期不一致（文件缺失、格式对不上、数字矛盾）就当作没识别到，不显示进度。
/// 与任务列表在同一次 SSH 轮询中完成，只对任务的工作目录做 `tail -n 1` / `awk` 这类轻量读取。
/// 新增软件时：在 `script` 里加一个分支输出 key=value，再在 `parse` 里解析即可。
struct AppProgress: Equatable {
    enum Kind: String { case nep, gnep, gpumd, vasp, lammps, custom }
    /// VASP 的计算类型。
    enum VaspMode: String { case md, relax, scf }

    struct Value: Equatable {
        var label: String
        var value: Double
    }

    struct Neighbor: Equatable {
        var radialActual: Int, radialMax: Int, angularActual: Int, angularMax: Int
    }

    var kind: Kind
    var dir: String
    var current: Double?
    var total: Double?
    /// nep.in / run.in 里是否写了目标（没写时用默认值，进度仅供参考）。
    var hasTarget = true
    var losses: [Value] = []
    var neighbor: Neighbor?
    /// 输出文件的最后修改时间（用来判断是否卡住）。
    var updatedAt: Date?
    /// 由引擎根据两次采样算出：每秒推进多少代 / 步。
    var rate: Double?
    /// 正常结束标记（VASP 的 OUTCAR 计时段、LAMMPS 的 Total wall time、自定义规则的结束文字）。
    /// nil：这种软件 / 规则没有结束标记。
    var endMarker: Bool?
    var vaspMode: VaspMode?
    /// 自定义规则的名称和单位。
    var customName = ""
    var customUnit = ""

    var title: String {
        switch kind {
        case .nep: return L("NEP 训练", "NEP training")
        case .gnep: return L("GNEP 训练", "GNEP training")
        case .gpumd: return L("GPUMD 模拟", "GPUMD MD")
        case .vasp:
            switch vaspMode ?? .scf {
            case .md: return "VASP MD"
            case .relax: return L("VASP 结构优化", "VASP relaxation")
            case .scf: return L("VASP 单点", "VASP SCF")
            }
        case .lammps: return "LAMMPS MD"
        case .custom: return customName
        }
    }

    var unit: String {
        switch kind {
        case .nep: return L("代", "gen")
        case .gnep: return "epoch"
        case .gpumd, .lammps: return L("步", "steps")
        case .vasp:
            switch vaspMode ?? .scf {
            case .md: return L("步", "steps")
            case .relax: return L("离子步", "ionic steps")
            case .scf: return L("电子步", "electronic steps")
            }
        case .custom: return customUnit
        }
    }

    var fraction: Double? {
        guard let c = current, let t = total, t > 0 else { return nil }
        return min(max(c / t, 0), 1)
    }

    var finished: Bool {
        if let m = endMarker { return m }
        guard let c = current, let t = total, hasTarget else { return false }
        return c >= t
    }

    /// 任务结束时能否判断成功 / 失败：有目标值或有结束标记。
    var canJudge: Bool { endMarker != nil || hasTarget }

    var eta: TimeInterval? {
        guard let c = current, let t = total, let r = rate, r > 0, c < t else { return nil }
        return (t - c) / r
    }

    /// 一行摘要，显示在任务行里。
    var summary: String {
        var parts: [String] = []
        if let c = current {
            let cur = Self.compact(c), tot = total.map(Self.compact)
            let u = unit.isEmpty ? "" : " \(unit)"
            parts.append(tot.map { "\(cur)/\($0)\(u)" } ?? "\(cur)\(u)")
        }
        switch kind {
        case .nep, .gnep:
            if let l = losses.first { parts.append("\(l.label) \(Self.sci(l.value))") }
        case .gpumd, .lammps:
            if let r = rate { parts.append(Self.compact(r) + L(" 步/秒", " steps/s")) }
        case .vasp, .custom:
            break
        }
        return parts.joined(separator: " · ")
    }

    static func compact(_ v: Double) -> String {
        let a = abs(v)
        if a >= 1e9 { return String(format: "%.2fG", v / 1e9) }
        if a >= 1e6 { return String(format: "%.2fM", v / 1e6) }
        if a >= 100 || v == v.rounded() {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.maximumFractionDigits = 0
            return f.string(from: NSNumber(value: v.rounded())) ?? String(Int(v.rounded()))
        }
        return String(format: "%.2f", v)
    }

    static func sci(_ v: Double) -> String {
        let a = abs(v)
        if a != 0 && (a < 1e-3 || a >= 1e4) { return String(format: "%.2e", v) }
        return String(format: "%.4f", v)
    }
}

enum AppDetectors {
    static let marker = RemoteScript.marker

    /// 远端脚本：收集"任务 ID | 工作目录"，再逐个目录识别软件。
    /// - 直连服务器：按进程名（pgrep -x）找进程，读 /proc/<pid>/cwd。
    /// - Slurm：squeue %Z 拿运行中作业的工作目录。
    /// shell 函数：从 /proc/<pid>/environ 读出所属 Slurm 作业号（数组元素为 主编号_序号）。
    /// 比 cgroup 可靠：不依赖 Slurm 的 cgroup / proctrack 配置。
    static let jobIDFunction = #"""
    si_pick() { (cd "$1" 2>/dev/null && ls -td -- $2 2>/dev/null | head -n 1); }
    si_jobid() { tr '\0' '\n' < /proc/$1/environ 2>/dev/null | awk -F= '$1=="SLURM_ARRAY_JOB_ID"{a=$2} $1=="SLURM_ARRAY_TASK_ID"{t=$2} $1=="SLURM_JOB_ID"{j=$2} END{if(a!=""&&t!="")print a"_"t; else if(j!="")print j}'; }

    """#

    static func script(host: HostConfig) -> String {
        let me = "\"$(id -un)\""
        let names = host.appProcessNames.replacingOccurrences(of: "'", with: "")
        // 候选进程：名字匹配，或者正在用 GPU，或者 CPU ≥ 50%。真正判断是哪种软件靠工作目录里的文件。
        let showLocal = host.kind == .direct || host.slurmAlsoProcesses
        let candidates = """
          for p in $( { pgrep -u \(me) -x '\(names)'
                        command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-compute-apps=pid --format=csv,noheader
                        ps -u \(me) -o pid=,pcpu= | awk '$2 >= 50 {print $1}'
                        \(host.kind == .slurm ? "for q in $(pgrep -u \(me)); do [ -n \"$(si_jobid $q)\" ] && echo $q; done" : "")
                      } 2>/dev/null | sort -un | head -n 60 ); do
            d=$(readlink /proc/$p/cwd 2>/dev/null) || continue
            # 属于 Slurm 作业的进程映射回作业号（单机 Slurm 能拿到作业真正运行的目录）
            j=$(si_jobid $p)
            if [ -n "$j" ]; then printf '%s|%s\\n' "$j" "$d"; \(showLocal ? "else printf '%s|%s\\n' \"$p\" \"$d\";" : "") fi
          done
        """
        let slurm = host.kind == .slurm ? "squeue -u \(me) -h -t R -o '%i|%Z' 2>/dev/null | head -n 40" : ""
        return """
        \(jobIDFunction)
        { \(slurm)
        \(candidates)
        } | awk -F'|' '!seen[$2]++' | while IFS='|' read -r id d; do
        \(dirBody(rules: ProgressRule.active.filter(\.isUsable)))
        done; true
        """
    }

    /// 任务结束时再读一次最终状态（只读这一个目录），避免"最后一次采样还没到目标"被误判为提前结束。
    static func finalStateScript(id: String, dir: String) -> String {
        directoryScript(id: id, dir: dir, rules: ProgressRule.active.filter(\.isUsable), builtin: true)
    }

    /// 只对一个目录跑识别。设置页"测试规则"用 `rules: [规则], builtin: false`。
    static func directoryScript(id: String, dir: String, rules: [ProgressRule], builtin: Bool) -> String {
        """
        \(jobIDFunction)
        id=\(SSHRunner.shellQuote(id)); d=\(SSHRunner.shellQuote(dir))
        case "$d" in "~"/*) d="$HOME/${d#\\~/}";; esac
        for _ in 1; do
        \(dirBody(rules: rules, builtin: builtin))
        done; true

        """
    }

    /// 对单个目录（变量 $id、$d）识别软件并输出 key=value。自定义规则排在内置识别前面。
    private static func dirBody(rules: [ProgressRule], builtin: Bool = true) -> String {
        var branches = rules.map(customBranch)
        if builtin { branches.append(builtinBranches) }
        guard !branches.isEmpty else { return "  :" }
        return "  [ -n \"$d\" ] && [ -d \"$d\" ] || continue\n  if "
            + branches.joined(separator: "\n  elif ")
            + "\n  fi"
    }

    /// 一条自定义规则：条件 + 输出。文件名已经过 isSafeFileName 检查，其余字符串一律 shellQuote。
    private static func customBranch(_ r: ProgressRule) -> String {
        let q = SSHRunner.shellQuote
        var body = """
        f="$d/$(si_pick "$d" '\(r.file)')"
            printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=custom; echo rule=\(r.id.uuidString)
        """
        if r.match == .keyword {
            body += "\n    grep -aiF -- \(q(r.pattern)) \"$f\" | tail -n 5 | cut -c1-300 | sed 's/^/tail=/'"
        } else {
            body += "\n    tail -n 40 \"$f\" | cut -c1-300 | sed 's/^/tail=/'"
        }
        if !r.totalFile.isEmpty {
            body += "\n    tf=$(si_pick \"$d\" '\(r.totalFile)'); [ -n \"$tf\" ] && grep -aiF -m 1 -- \(q(r.totalKeyword)) \"$d/$tf\" | cut -c1-300 | sed 's/^/totalline=/'"
        }
        if !r.doneMarker.isEmpty {
            body += "\n    if tail -n 50 \"$f\" | grep -qaF -- \(q(r.doneMarker)); then echo done=1; else echo done=0; fi"
        }
        body += "\n    echo \"mtime=$(stat -c %Y \"$f\" 2>/dev/null)\""
        return "[ -n \"$(si_pick \"$d\" '\(r.file)')\" ]; then\n    " + body
    }

    /// LAMMPS：从最后一个 run 命令开始读 log.lammps。第一行必须是 "run <整数>"，之后要找到含 Step 列的 thermo 表头，
    /// 数据行列数和表头一致且全是数字。出现 minimize / rerun、多余的表头、upto / every 等都标记 bad。
    private static let lammpsAwk = #"""
    awk 'function isnum(x) { return x ~ /^[-+]?([0-9]+[.]?[0-9]*|[.][0-9]+)([eE][-+]?[0-9]+)?$/ }
    NR == 1 { total = $2; if (NF < 2 || $2 !~ /^[0-9]+$/) bad = 1
              for (i = 3; i <= NF; i++) if ($i == "upto" || $i == "every") bad = 1; next }
    /^[ 	]*(minimize|rerun)([ 	]|$)/ { bad = 1 }
    /^Loop time of/ { if (hdr) loop = 1; next }
    loop { next }
    !hdr { k = 0; for (i = 1; i <= NF; i++) if ($i == "Step") k = i
           if (k) { hdr = 1; n = NF }; next }
    $k == "Step" { bad = 1; next }
    NF == n { ok = 1; for (i = 1; i <= NF; i++) if (!isnum($i)) { ok = 0; break }
              if (ok && $k ~ /^[0-9]+$/) { if (first == "") first = $k; last = $k } }
    END { print "total=" total; print "first=" first; print "last=" last; print "loop=" (loop ? 1 : 0); print "bad=" (bad ? 1 : 0) }'
    """#

    /// VASP：INCAR 里的 NSW / IBRION（去掉注释，支持分号分隔），OSZICAR 末尾的离子步 / 电子步。
    private static let vaspIncarAwk = #"""
    awk '{ sub(/[!#].*/, ""); n = split($0, parts, ";")
           for (i = 1; i <= n; i++) { s = toupper(parts[i])
             if (s ~ /^[ 	]*NSW[ 	]*=/) { sub(/^[^=]*=[ 	]*/, "", s); split(s, v, " "); print "nsw=" v[1] }
             if (s ~ /^[ 	]*IBRION[ 	]*=/) { sub(/^[^=]*=[ 	]*/, "", s); split(s, v, " "); print "ibrion=" v[1] } } }'
    """#
    private static let vaspOszicarAwk = #"""
    awk '$1 ~ /^[0-9]+$/ && $2 ~ /^[FT]=/ { ion = $1 }
         /^[A-Z][A-Z][A-Z ]:/ { s = substr($0, 5); split(s, a, " "); if (a[1] ~ /^[0-9]+$/) elec = a[1] }
         END { print "ionic=" ion; print "elec=" elec }'
    """#

    private static var builtinBranches: String {
        """
        [ -f "$d/loss.out" ] && [ -f "$d/nep.in" ]; then
            printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=nep
            awk '$1=="generation" && $2~/^[0-9]+$/ {print "total="$2; exit}' "$d/nep.in"
            echo "last=$(tail -n 1 "$d/loss.out")"; echo "mtime=$(stat -c %Y "$d/loss.out" 2>/dev/null)"
          elif [ -f "$d/loss.out" ] && [ -f "$d/gnep.in" ]; then
            printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=gnep
            awk '$1=="epoch" && $2~/^[0-9]+$/ {print "total="$2; exit}' "$d/gnep.in"
            echo "last=$(tail -n 1 "$d/loss.out")"; echo "mtime=$(stat -c %Y "$d/loss.out" 2>/dev/null)"
          elif [ -f "$d/run.in" ] && { [ -f "$d/neighbor.out" ] || [ -f "$d/thermo.out" ]; }; then
            printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=gpumd
            awk '$1=="run" && $2~/^[0-9]+$/ {s+=$2} END {if (s>0) print "total="s}' "$d/run.in"
            awk '$1=="dump_thermo" && $2~/^[0-9]+$/ && $2>0 {print "interval="$2; exit}' "$d/run.in"
            if [ -f "$d/neighbor.out" ]; then
              echo "neighbor=$(tail -n 1 "$d/neighbor.out")"; echo "mtime=$(stat -c %Y "$d/neighbor.out" 2>/dev/null)"
            else
              echo "thermo_rows=$(grep -cv '^[[:space:]]*#' "$d/thermo.out")"; echo "mtime=$(stat -c %Y "$d/thermo.out" 2>/dev/null)"
            fi
          elif [ -f "$d/INCAR" ] && [ -f "$d/OSZICAR" ]; then
            printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=vasp
            \(vaspIncarAwk) "$d/INCAR"
            tail -n 3000 "$d/OSZICAR" | \(vaspOszicarAwk)
            if [ -f "$d/OUTCAR" ]; then
              if tail -n 400 "$d/OUTCAR" | grep -q 'General timing and accounting'; then echo done=1; else echo done=0; fi
            fi
            echo "mtime=$(stat -c %Y "$d/OSZICAR" 2>/dev/null)"
          elif [ -f "$d/log.lammps" ]; then
            L=$(grep -naE '^[[:space:]]*run[[:space:]]' "$d/log.lammps" | tail -n 1 | cut -d: -f1)
            if [ -n "$L" ]; then
              printf '\(marker)DIR %s|%s\\n' "$id" "$d"; echo kind=lammps
              tail -n +"$L" "$d/log.lammps" | \(lammpsAwk)
              if tail -n 30 "$d/log.lammps" | grep -q '^Total wall time'; then echo done=1; else echo done=0; fi
              echo "mtime=$(stat -c %Y "$d/log.lammps" 2>/dev/null)"
            fi
        """
    }

    private static let neighborRegex = try! NSRegularExpression(
        pattern: #"^Neighbor info at step\s+(\d+):\s*radial\(max=(\d+),actual=(\d+)\),\s*angular\(max=(\d+),actual=(\d+)\)"#)

    /// 解析 "apps" 段：返回 任务ID -> 进度。
    /// `rules`：解析自定义规则用的规则表（默认是当前设置里的；测试规则时传入正在编辑的那一条）。
    static func parse(_ lines: [String], rules: [ProgressRule]? = nil) -> [String: AppProgress] {
        var out: [String: AppProgress] = [:]
        var id: String?
        var dir = ""
        var kv: [String: String] = [:]
        var tails: [String] = []

        func flush() {
            defer { kv = [:]; tails = [] }
            guard let id, let kind = kv["kind"].flatMap(AppProgress.Kind.init(rawValue:)) else { return }
            var p = AppProgress(kind: kind, dir: dir)
            p.updatedAt = kv["mtime"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            switch kv["done"] {
            case "1": p.endMarker = true
            case "0": p.endMarker = false
            default: break
            }
            switch kind {
            case .nep, .gnep:
                if let t = kv["total"].flatMap(Double.init) { p.total = t } else {
                    p.total = kind == .nep ? 100_000 : 50
                    p.hasTarget = false
                }
                let nums = (kv["last"] ?? "").split(separator: " ").compactMap { Double($0) }
                if !nums.isEmpty {
                    p.current = nums[0]
                    // loss.out 列：gen Total L1 L2 E-train F-train V-train [E-test F-test V-test]（与 plt_train.py 一致）
                    let labels = nums.count >= 7
                        ? ["Total", "L1", "L2", "Energy", "Force", "Virial", "E-test", "F-test", "V-test"]
                        : ["Loss", "Energy", "Force", "Virial"]
                    for (i, v) in nums.dropFirst().enumerated() where i < labels.count {
                        p.losses.append(.init(label: labels[i], value: v))
                    }
                    // 没有测试集时 test 列全是 0，不显示。
                    let tests = p.losses.filter { $0.label.hasSuffix("-test") }
                    if !tests.isEmpty, tests.allSatisfy({ $0.value == 0 }) {
                        p.losses.removeAll { $0.label.hasSuffix("-test") }
                    }
                }
            case .gpumd:
                p.total = kv["total"].flatMap(Double.init)
                p.hasTarget = p.total != nil
                if let line = kv["neighbor"],
                   let m = neighborRegex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) {
                    let ns = line as NSString
                    let n = (1...5).map { Int(ns.substring(with: m.range(at: $0))) ?? 0 }
                    p.current = Double(n[0])
                    p.neighbor = .init(radialActual: n[2], radialMax: n[1], angularActual: n[4], angularMax: n[3])
                } else if let rows = kv["thermo_rows"].flatMap(Double.init), let iv = kv["interval"].flatMap(Double.init) {
                    p.current = rows * iv
                }
            case .vasp:
                guard let v = parseVasp(kv) else { return }
                p.vaspMode = v.mode; p.current = v.current; p.total = v.total; p.hasTarget = v.total != nil
            case .lammps:
                guard let l = parseLammps(kv) else { return }
                p.current = l.current; p.total = l.total
            case .custom:
                guard let rid = kv["rule"].flatMap(UUID.init(uuidString:)),
                      let rule = (rules ?? ProgressRule.active).first(where: { $0.id == rid }),
                      let x = rule.extract(from: tails) else { return }
                p.customName = rule.name
                p.customUnit = rule.unit
                p.current = x.current
                p.total = x.total ?? Double(rule.total)
                    ?? kv["totalline"].flatMap { ProgressRule.number(after: rule.totalKeyword, in: $0) }
                if let t = p.total {
                    // 目标值不合理或当前值超过目标值：当作没识别到
                    guard t > 0, x.current >= 0, x.current <= t * 1.000001 else { return }
                }
                p.hasTarget = p.total != nil
                if rule.doneMarker.isEmpty { p.endMarker = nil }
            }
            out[id] = p
        }

        for line in lines {
            if line.hasPrefix(marker + "DIR ") {
                flush()
                let rest = line.dropFirst((marker + "DIR ").count)
                if let bar = rest.firstIndex(of: "|") {
                    id = String(rest[..<bar]); dir = String(rest[rest.index(after: bar)...])
                } else { id = nil }
            } else if line.hasPrefix("tail=") {
                tails.append(String(line.dropFirst(5)))
            } else if let eq = line.firstIndex(of: "=") {
                kv[String(line[..<eq])] = String(line[line.index(after: eq)...])
            }
        }
        flush()
        return out
    }
    /// VASP：NSW ≤ 0 → 单点（电子步）；IBRION=0 → MD（离子步 / NSW）；IBRION=1/2/3 → 结构优化（只显示离子步）。
    /// 其它 IBRION（声子等）或写法看不懂时返回 nil。
    static func parseVasp(_ kv: [String: String]) -> (mode: AppProgress.VaspMode, current: Double, total: Double?)? {
        var nsw = 0, ibrion: Int?
        if let s = kv["nsw"] { guard let v = Int(s) else { return nil }; nsw = v }
        if let s = kv["ibrion"] { guard let v = Int(s) else { return nil }; ibrion = v }
        let ionic = kv["ionic"].flatMap(Int.init), elec = kv["elec"].flatMap(Int.init)
        if nsw <= 0 {
            guard let e = elec else { return nil }
            return (.scf, Double(e), nil)
        }
        switch ibrion ?? 0 {
        case 0:
            guard let i = ionic, i <= nsw else { return nil }
            return (.md, Double(i), Double(nsw))
        case 1, 2, 3:
            guard let i = ionic else { return nil }
            return (.relax, Double(i), nil)
        default:
            return nil
        }
    }

    /// LAMMPS：当前步 = 最后一行的 Step − 这段 run 第一行的 Step，目标 = run 的步数。任何一处不对就返回 nil。
    static func parseLammps(_ kv: [String: String]) -> (current: Double, total: Double)? {
        guard kv["bad"] == "0",
              let total = kv["total"].flatMap(Double.init), total > 0,
              let first = kv["first"].flatMap(Double.init),
              let last = kv["last"].flatMap(Double.init) else { return nil }
        let cur = last - first
        guard cur >= 0, cur <= total else { return nil }
        return (cur, total)
    }
}

// MARK: - 设置页"测试规则"

struct RuleTestResult: Equatable {
    var ok: Bool
    var headline: String
    /// 补充说明，以及没匹配上时文件的最后几行。
    var notes: [String] = []
    var lines: [String] = []
}

extension AppDetectors {
    /// 先报告目录和文件是否存在，再跑这一条规则（不跑内置识别）。只读。
    static func ruleTestScript(dir: String, rule: ProgressRule) -> String {
        var s = """
        \(jobIDFunction)
        d=\(SSHRunner.shellQuote(dir))
        case "$d" in "~"/*) d="$HOME/${d#\\~/}";; esac
        if [ ! -d "$d" ]; then echo '\(marker)NODIR'; else
          echo "picked=$(si_pick "$d" '\(rule.file)')"

        """
        if !rule.totalFile.isEmpty { s += "  echo \"tpicked=$(si_pick \"$d\" '\(rule.totalFile)')\"\n" }
        if rule.match == .keyword {
            // 没匹配上时给用户看文件最后几行
            s += "  f=\"$d/$(si_pick \"$d\" '\(rule.file)')\"; [ -f \"$f\" ] && tail -n 5 \"$f\" | cut -c1-200 | sed 's/^/last=/'\n"
        }
        s += "fi\n"
        return s + directoryScript(id: "t", dir: dir, rules: [rule], builtin: false)
    }

    static func interpretTest(_ stdout: String, rule: ProgressRule) -> RuleTestResult {
        let lines = stdout.components(separatedBy: "\n")
        if lines.contains(marker + "NODIR") { return .init(ok: false, headline: L("服务器上没有这个目录", "Directory not found on the server")) }
        func value(_ key: String) -> String? {
            lines.first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
        }
        guard let picked = value("picked") else {
            return .init(ok: false, headline: L("没有收到服务器的回应", "No response from the server"))
        }
        if picked.isEmpty {
            return .init(ok: false, headline: L("目录里没有匹配「\(rule.file)」的文件", "No file matching “\(rule.file)” in this directory"))
        }
        var notes = [L("文件：", "File: ") + picked]
        if !rule.totalFile.isEmpty, value("tpicked")?.isEmpty != false {
            notes.append(L("没找到目标值文件「\(rule.totalFile)」", "Target file “\(rule.totalFile)” not found"))
        }
        if let a = AppDetectors.parse(lines, rules: [rule])["t"], let c = a.current {
            var head = L("当前值 ", "Current ") + AppProgress.compact(c)
            if let t = a.total {
                head += L(" · 目标值 ", " · target ") + AppProgress.compact(t)
                if let f = a.fraction { head += "（\(Format.percent(f))）" }
            } else {
                head += L(" · 没有目标值，只显示当前值", " · no target, showing the current value only")
            }
            if let m = a.endMarker { notes.append(m ? L("已出现结束标记", "End marker found") : L("还没有出现结束标记", "End marker not found yet")) }
            return .init(ok: true, headline: head, notes: notes)
        }
        let tails = lines.filter { $0.hasPrefix("tail=") }.map { String($0.dropFirst(5)) }
        let shown = rule.match == .keyword
            ? lines.filter { $0.hasPrefix("last=") }.map { String($0.dropFirst(5)) }
            : Array(tails.suffix(5))
        if let x = rule.extract(from: tails), let t = x.total ?? Double(rule.total) {
            return .init(ok: false, headline: L("当前值 \(AppProgress.compact(x.current)) 超过了目标值 \(AppProgress.compact(t))，不会显示进度",
                                                "Current \(AppProgress.compact(x.current)) exceeds target \(AppProgress.compact(t)); progress won't be shown"),
                         notes: notes, lines: shown)
        }
        let head = rule.match == .keyword
            ? L("文件里没有「\(rule.pattern)」后面紧跟数字的行", "No line has a number right after “\(rule.pattern)”")
            : L("文件最后 40 行都没有匹配上正则", "The regex matched none of the last 40 lines")
        return .init(ok: false, headline: head, notes: notes + [L("文件最后几行：", "Last lines of the file:")], lines: shown)
    }
}
