import Foundation

/// 详情页里的小曲线：NEP / GNEP 的 loss，VASP 结构优化每个离子步的能量和最大力（两张并排）。
/// 只在详情页打开时读取，并且是增量的：记住已经读到第几行和文件第一行，下次只取新增的行；
/// 第一行变了（重新训练）或文件变短时从头读。
struct AppCurve: Equatable {
    struct Series: Equatable {
        var name: String
        var points: [CGPoint]
        /// 辅助线（比如"目前最低"）：画得淡一些。
        var faint = false
        /// 每个点画一个圆点（NEB 能垒图的像点）；图例里不显示最后一个值。
        var markers = false
    }

    var title: String
    var series: [Series]
    /// loss 跨好几个数量级，用对数坐标。
    var logY: Bool
    var xLabel: String
    /// 收敛目标（虚线），比如 VASP 的 |EDIFFG|（EDIFFG < 0 时按力收敛）。
    var threshold: Double? = nil
    /// 图右上角的说明，比如"按能量收敛 ΔE < 0.001 eV"（这时不画目标线）。
    var note: String? = nil
    /// 柱子（NEB 每个像点的最大力），用自己的纵轴（0 到最大值）；有柱子时 threshold 画在柱子的纵轴上。
    var bars: [CGPoint] = []
    var barsLabel = ""
}

/// 增量读取的缓存（每台服务器 + 文件一份）。
struct CurveCache {
    var lineCount = 0
    var head = ""
    var rows: [[Double]] = []
    /// 曲线以外的值（如 ediffg）。
    var extra: [String: String] = [:]
}

enum AppCurves {
    static let marker = RemoteScript.marker
    /// 一次最多取这么多行（第一次打开很长的 loss.out 时只取最后这些）。
    static let maxRows = 50_000

    enum Source: Equatable {
        case loss(path: String, gnep: Bool)
        case vaspEnergy(path: String)
        /// OUTCAR 每个离子步 TOTAL-FORCE 块里最大的原子受力 |F|；INCAR 的 EDIFFG 作为收敛目标。
        case vaspForce(path: String)
        /// NEB：读 00…N+1 各像点的 OSZICAR / OUTCAR，画能垒图和能垒随离子步的变化（一次读取出两张图）。
        case neb(dir: String)

        var path: String {
            switch self {
            case .loss(let p, _), .vaspEnergy(let p), .vaspForce(let p): return p
            case .neb(let d): return d
            }
        }
    }

    /// 哪些任务有曲线：NEP / GNEP 训练、VASP 结构优化（能量 + 最大力）。
    static func sources(for app: AppProgress) -> [Source] {
        switch app.kind {
        case .nep: return [.loss(path: app.dir + "/loss.out", gnep: false)]
        case .gnep: return [.loss(path: app.dir + "/loss.out", gnep: true)]
        case .vasp where app.vaspMode == .relax: return [.vaspEnergy(path: app.dir + "/OSZICAR"), .vaspForce(path: app.dir + "/OUTCAR")]
        case .vasp where app.vaspMode == .neb: return [.neb(dir: app.dir)]
        default: return []
        }
    }

    /// OUTCAR 里每个离子步的最大力（和 VASP 判断 EDIFFG 收敛时的口径一致）：
    /// - 有 VTST 补丁打印的 `FORCES: max atom, RMS` 就直接用它的 max atom（和 `grep RMS OUTCAR` 看到的一样），输出 `row=1 值`；
    /// - 否则读 TOTAL-FORCE 块（表头、虚线、每个原子 x y z Fx Fy Fz、虚线），按 POSCAR 的 Selective dynamics 去掉固定（F）的方向
    ///   再取最大的 |F|，输出 `row=0 值`。两种都有时曲线只用 VTST 的。
    /// n= 报告最后一个读完的块（或 VTST 行）所在的行，正在写的半个块下次重读，VTST 行也不会重复计数。
    static let forceAwk = #"""
    awk -v off="$off" -v mask="$mask" '
    /FORCES: max atom, RMS/ { printf "row=1 %.6g\n", $5; last = NR; next }
    /TOTAL-FORCE/ { inb = 1; d = 0; m = 0; a = 0; next }
    inb && /^ *-+ *$/ { d++; if (d == 2) { printf "row=0 %.6g\n", sqrt(m); inb = 0; last = NR }; next }
    inb && d == 1 && NF >= 6 {
      a++; fx = $4; fy = $5; fz = $6
      if (length(mask) >= 3 * a) { if (substr(mask, 3 * a - 2, 1) == "F") fx = 0; if (substr(mask, 3 * a - 1, 1) == "F") fy = 0; if (substr(mask, 3 * a, 1) == "F") fz = 0 }
      f = fx * fx + fy * fy + fz * fz; if (f > m) m = f
    }
    END { print "n=" off + last }'
    """#

    /// 远端脚本：输出 n=总行数，必要时 reset=1，然后是 row= 开头的数据行。
    /// `head -n $((n-off))` 只取 wc 数到的完整行，正在写的半行不读，偏移量才对得上。
    static func script(_ src: Source, offset: Int, head: String) -> String {
        if case .vaspForce = src { return forceScript(src.path, offset: offset, head: head) }
        if case .neb(let dir) = src { return nebScript(dir) }
        let filter: String
        switch src {
        case .loss:
            filter = #"awk 'NF >= 2 && $1 ~ /^[0-9]+$/ { print }' | cut -c1-300"#
        case .vaspEnergy, .vaspForce, .neb:
            filter = #"awk '$1 ~ /^[0-9]+$/ && $2 ~ /^F=/ { for (i = 3; i <= NF; i++) if ($i ~ /^E0=/) { v = substr($i, 4); if (v == "") v = $(i + 1); print $1, v; break } }'"#
        }
        return """
        f=\(SSHRunner.shellQuote(src.path))
        if [ ! -f "$f" ]; then echo '\(marker)NOFILE'; exit 0; fi
        n=$(wc -l < "$f" | tr -d ' '); h=$(head -n 1 "$f" | cut -c1-200)
        off=\(max(0, offset))
        if [ "$h" != \(SSHRunner.shellQuote(head)) ] || [ "$n" -lt "$off" ]; then off=0; echo reset=1; fi
        if [ $((n - off)) -gt \(maxRows) ]; then off=$((n - \(maxRows))); echo reset=1; fi
        echo "n=$n"; echo "head=$h"
        tail -n +$((off + 1)) "$f" | head -n $((n - off)) | \(filter) | sed 's/^/row=/'

        """
    }

    /// OUTCAR 可能有几十万行：不限制行数（awk 一遍就过去了），增量读取保证之后每次只读新增部分。
    static func forceScript(_ path: String, offset: Int, head: String) -> String {
        """
        f=\(SSHRunner.shellQuote(path))
        if [ ! -f "$f" ]; then echo '\(marker)NOFILE'; exit 0; fi
        n=$(wc -l < "$f" | tr -d ' '); h=$(head -n 1 "$f" | cut -c1-200)
        off=\(max(0, offset))
        if [ "$h" != \(SSHRunner.shellQuote(head)) ] || [ "$n" -lt "$off" ]; then off=0; echo reset=1; fi
        echo "head=$h"
        grep -m 1 '^ *EDIFFG *=' "$f" | awk '{ print "ediffg=" $3 }'
        sed -n 's/^[[:space:]]*EDIFFG[[:space:]]*=[[:space:]]*\\([-+.0-9eEdD]*\\).*/ediffg=\\1/p' "$(dirname "$f")/INCAR" 2>/dev/null | tail -n 1
        mask=$(awk 'NR == 6 && $1 ~ /^[0-9]+$/ { for (i = 1; i <= NF; i++) n += $i; L = 7 }
        NR == 7 && !L { for (i = 1; i <= NF; i++) n += $i; L = 8 }
        L && NR == L { if ($1 ~ /^[Ss]/) sel = 1; else exit }
        sel && NR > L + 1 && NR <= L + 1 + n { m = m (NF >= 6 ? substr($4, 1, 1) substr($5, 1, 1) substr($6, 1, 1) : "TTT") }
        END { if (sel) print m }' "$(dirname "$f")/POSCAR" 2>/dev/null)
        tail -n +$((off + 1)) "$f" | head -n $((n - off)) | \(forceAwk)

        """
    }

    /// NEB：每次整个重读（OSZICAR 很小，OUTCAR 只读末尾）。输出 ediffg= / images=，以及
    /// `row=像点 离子步 E0`（中间像点的 OSZICAR，每一步）、`row=像点 0 能量`（OUTCAR 最后的 energy(sigma→0)，端点用它）、
    /// `row=像点 -1 力`（OUTCAR 最后的 VTST FORCES: max atom）。
    static func nebScript(_ dir: String) -> String {
        """
        d=\(SSHRunner.shellQuote(dir))
        if [ ! -d "$d/01" ]; then echo '\(marker)NOFILE'; exit 0; fi
        echo n=0; echo reset=1; echo head=
        sed -n 's/^[[:space:]]*EDIFFG[[:space:]]*=[[:space:]]*\\([-+.0-9eEdD]*\\).*/ediffg=\\1/p' "$d/INCAR" 2>/dev/null | tail -n 1
        awk '{ sub(/[!#].*/, ""); s = toupper($0) } s ~ /^[[:space:]]*IMAGES[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, "", s); split(s, v, " "); print "images=" v[1]; exit }' "$d/INCAR" 2>/dev/null
        for s in "$d"/[0-9][0-9]; do
          i=${s##*/}; i=$((10#$i))
          [ -f "$s/OSZICAR" ] && awk -v i="$i" '$1 ~ /^[0-9]+$/ && $2 ~ /^F=/ { for (k = 3; k <= NF; k++) if ($k ~ /^E0=/) { v = substr($k, 4); if (v == "") v = $(k + 1); print "row=" i, $1, v; break } }' "$s/OSZICAR"
          [ -f "$s/OUTCAR" ] && tail -n 25000 "$s/OUTCAR" | awk -v i="$i" '/energy  without entropy/ { e = $NF } /FORCES: max atom, RMS/ { f = $5 } END { if (e != "") print "row=" i, 0, e; if (f != "") print "row=" i, -1, f }'
        done
        true

"""
    }

    /// 把一次输出合并进缓存。读不到文件时返回 nil。
    static func merge(_ stdout: String, into cache: CurveCache) -> CurveCache? {
        let lines = stdout.components(separatedBy: "\n")
        if lines.contains(marker + "NOFILE") { return nil }
        guard let n = lines.first(where: { $0.hasPrefix("n=") }).flatMap({ Int($0.dropFirst(2)) }) else { return nil }
        var c = cache
        if lines.contains("reset=1") { c.rows = [] }
        c.lineCount = n
        c.head = lines.first(where: { $0.hasPrefix("head=") }).map { String($0.dropFirst(5)) } ?? ""
        if let e = lines.first(where: { $0.hasPrefix("ediffg=") }) { c.extra["ediffg"] = String(e.dropFirst(7)) }
        if let e = lines.first(where: { $0.hasPrefix("images=") }) { c.extra["images"] = String(e.dropFirst(7)) }
        for l in lines where l.hasPrefix("row=") {
            let nums = l.dropFirst(4).split(separator: " ").compactMap { Double($0) }
            if nums.count >= 2 { c.rows.append(nums) }
        }
        return c
    }

    /// 一个来源可能出好几张图（NEB 出两张）。
    static func curves(_ src: Source, rows: [[Double]], extra: [String: String] = [:]) -> [AppCurve] {
        if case .neb = src { return nebCurves(rows: rows, extra: extra) }
        return [curve(src, rows: rows, extra: extra)].compactMap { $0 }
    }

    /// NEB 两张图：
    /// - 能垒图：横轴像点 0…N+1，曲线是相对初态的能量（中间像点取最新一步，端点取各自 OUTCAR 的最后能量，和 VTST nebef.pl 一致），
    ///   柱子是每个中间像点的 VTST 最大力（自己的纵轴），EDIFFG < 0 时画虚线目标；右上角写正向 / 逆向能垒。
    /// - 能垒随离子步：每一步所有中间像点都有能量时，最高的中间像点 − 初态。
    static func nebCurves(rows: [[Double]], extra: [String: String]) -> [AppCurve] {
        var steps: [Int: [Int: Double]] = [:]          // 像点 -> 离子步 -> E0（OSZICAR）
        var last: [Int: Double] = [:], force: [Int: Double] = [:]
        for r in rows where r.count >= 3 {
            let i = Int(r[0]), st = Int(r[1])
            if st > 0 { steps[i, default: [:]][st] = r[2] } else if st == 0 { last[i] = r[2] } else { force[i] = r[2] }
        }
        let allIdx = Set(steps.keys).union(last.keys)
        guard let maxIdx = allIdx.max() else { return [] }
        let n = extra["images"].flatMap(Int.init) ?? max(maxIdx - 1, 1)
        let middle = (1...max(n, 1)).filter { steps[$0] != nil }
        guard !middle.isEmpty, let s = middle.compactMap({ steps[$0]?.keys.max() }).min(), s >= 1 else { return [] }
        let e0 = last[0]
        // 没有初态 OUTCAR：相对第 1 个像点
        func ref(_ st: Int) -> Double? { e0 ?? steps[1]?[st] }
        guard let r0 = ref(s) else { return [] }
        var profile: [CGPoint] = []
        if let e = e0 { profile.append(CGPoint(x: 0, y: e - r0)) }
        for i in middle { if let e = steps[i]?[s] { profile.append(CGPoint(x: Double(i), y: e - r0)) } }
        if let e = last[n + 1] { profile.append(CGPoint(x: Double(n + 1), y: e - r0)) }
        guard profile.count >= 2 else { return [] }
        let top = profile.filter { $0.x > 0 }.map(\.y).max() ?? 0
        var note = e0 != nil ? L("能垒 \(String(format: "%.3f", top)) eV", "barrier \(String(format: "%.3f", top)) eV")
                             : L("相对第 1 个像点（00 没有 OUTCAR）", "relative to image 1 (no OUTCAR in 00)")
        if e0 != nil, let fe = last[n + 1] { note += L(" · 逆向 \(String(format: "%.3f", top - (fe - r0)))", " · reverse \(String(format: "%.3f", top - (fe - r0)))") }
        let bars = middle.compactMap { i in force[i].map { CGPoint(x: Double(i), y: $0) } }
        let ediffg = extra["ediffg"].flatMap { Double($0.replacingOccurrences(of: "d", with: "e").replacingOccurrences(of: "D", with: "e")) }
        var out = [AppCurve(title: L("能垒图（eV）", "Energy profile (eV)"),
                            series: [.init(name: L("能量", "energy"), points: profile, markers: true)],
                            logY: false, xLabel: L("像点", "image"),
                            threshold: bars.isEmpty ? nil : ediffg.flatMap { $0 < 0 ? -$0 : nil }, note: nil,
                            bars: bars, barsLabel: L("力", "force"))]
        // 能垒随离子步
        var history: [CGPoint] = []
        for st in 1...s {
            let es = middle.compactMap { steps[$0]?[st] }
            guard es.count == middle.count, let r = ref(st), let m = es.max() else { continue }
            history.append(CGPoint(x: Double(st), y: m - r))
        }
        if history.count >= 2 {
            // 能垒的数字写在这张图的右上角（能垒图的最高点通常在中间偏上，放不下）
            out.append(AppCurve(title: L("能垒（eV）", "Barrier (eV)"), series: [.init(name: L("能垒", "barrier"), points: downsample(history))],
                                logY: false, xLabel: L("离子步", "ionic step"), note: note))
        }
        return out
    }

    static func curve(_ src: Source, rows: [[Double]], extra: [String: String] = [:]) -> AppCurve? {
        if case .neb = src { return nebCurves(rows: rows, extra: extra).first }
        guard rows.count >= 2 else { return nil }
        switch src {
        case .loss(_, let gnep):
            // NEP：gen Total L1 L2 E F V [E-test F-test V-test]；GNEP：epoch Loss E F V
            let cols: [(String, Int)] = gnep
                ? [("Loss", 1), (L("能量", "Energy"), 2), (L("力", "Force"), 3), (L("维里", "Virial"), 4)]
                : (rows.last!.count >= 7
                    ? [("Total", 1), (L("能量", "Energy"), 4), (L("力", "Force"), 5), (L("维里", "Virial"), 6)]
                    : [("Loss", 1), (L("能量", "Energy"), 2), (L("力", "Force"), 3), (L("维里", "Virial"), 4)])
            let series: [AppCurve.Series] = cols.compactMap { name, i in
                let pts = rows.compactMap { r -> CGPoint? in
                    guard i < r.count, r[i] > 0 else { return nil }
                    return CGPoint(x: r[0], y: r[i])
                }
                return pts.count >= 2 ? .init(name: name, points: downsample(pts)) : nil
            }
            guard !series.isEmpty else { return nil }
            return AppCurve(title: "Loss", series: series, logY: true, xLabel: gnep ? "epoch" : L("代", "gen"))
        case .vaspEnergy:
            let pts = rows.map { CGPoint(x: $0[0], y: $0[1]) }
            return AppCurve(title: L("能量 E0（eV）", "Energy E0 (eV)"), series: [.init(name: "E0", points: downsample(pts))],
                            logY: false, xLabel: L("离子步", "ionic step"))
        case .neb:
            return nil
        case .vaspForce:
            // 有 VTST 的 max atom（第一列是 1）就只用它，否则用自己算的（第一列是 0）。按顺序就是离子步 1、2、3…
            let vtst = rows.filter { $0[0] == 1 }
            let used = vtst.isEmpty ? rows.filter { $0[0] == 0 } : vtst
            guard used.count >= 2 else { return nil }
            let pts = used.enumerated().map { CGPoint(x: Double($0.offset + 1), y: max($0.element[1], 1e-6)) }
            // 共轭梯度（IBRION=2）会走试探步，最大力会上下跳：再画一条"目前最低"的淡线。
            var low = Double.infinity
            let lows = pts.map { p -> CGPoint in low = min(low, p.y); return CGPoint(x: p.x, y: low) }
            // EDIFFG（OUTCAR 里 VASP 实际用的值，包括默认值）：< 0 按力收敛，|EDIFFG| 是目标（eV/Å）；≥ 0 按能量收敛。
            let ediffg = extra["ediffg"].flatMap { Double($0.replacingOccurrences(of: "d", with: "e").replacingOccurrences(of: "D", with: "e")) }
            let target = ediffg.flatMap { $0 < 0 ? -$0 : nil }
            let note = ediffg.flatMap { $0 >= 0 ? L("按能量收敛 ΔE < \(AppProgress.sci($0)) eV", "energy criterion ΔE < \(AppProgress.sci($0)) eV") : nil }
            return AppCurve(title: L("最大力（eV/Å）", "Max force (eV/Å)"),
                            series: [.init(name: "|F|max", points: downsample(pts)), .init(name: L("最低", "lowest"), points: downsample(lows), faint: true)],
                            logY: true, xLabel: L("离子步", "ionic step"), threshold: target, note: note)
        }
    }

    /// 点太多时等间隔抽样（保留首尾），画图用不到上万个点。
    static func downsample(_ pts: [CGPoint], to limit: Int = 400) -> [CGPoint] {
        guard pts.count > limit else { return pts }
        let step = Double(pts.count - 1) / Double(limit - 1)
        return (0..<limit).map { pts[min(Int((Double($0) * step).rounded()), pts.count - 1)] }
    }
}

extension MonitorEngine {
    /// 读取（增量）任务的曲线（VASP 结构优化有两张）。读不到或连接失败的那张不返回。
    func fetchCurves(host: HostConfig, app: AppProgress) async -> [AppCurve] {
        var out: [AppCurve] = []
        for src in AppCurves.sources(for: app) {
            let key = host.id.uuidString + "|" + src.path
            let cache = curveCaches[key] ?? CurveCache()
            let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                        script: AppCurves.script(src, offset: cache.lineCount, head: cache.head), timeout: 30)
            var current = cache
            if r.status == 0, let merged = AppCurves.merge(r.stdout, into: cache) {
                curveCaches[key] = merged
                current = merged
            }
            out += AppCurves.curves(src, rows: current.rows, extra: current.extra)
        }
        return out
    }
}
