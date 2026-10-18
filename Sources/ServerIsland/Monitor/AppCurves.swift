import Foundation

/// 详情页里的小曲线：NEP / GNEP 的 loss，VASP 结构优化每个离子步的能量和最大力（两张并排）。
/// 只在详情页打开时读取，并且是增量的：记住已经读到第几行和文件第一行，下次只取新增的行；
/// 第一行变了（重新训练）或文件变短时从头读。
struct AppCurve: Equatable {
    struct Series: Equatable {
        var name: String
        var points: [CGPoint]
    }

    var title: String
    var series: [Series]
    /// loss 跨好几个数量级，用对数坐标。
    var logY: Bool
    var xLabel: String
    /// 收敛目标（虚线），比如 VASP 的 |EDIFFG|（EDIFFG < 0 时按力收敛）。
    var threshold: Double? = nil
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

        var path: String {
            switch self {
            case .loss(let p, _), .vaspEnergy(let p), .vaspForce(let p): return p
            }
        }
    }

    /// 哪些任务有曲线：NEP / GNEP 训练、VASP 结构优化（能量 + 最大力）。
    static func sources(for app: AppProgress) -> [Source] {
        switch app.kind {
        case .nep: return [.loss(path: app.dir + "/loss.out", gnep: false)]
        case .gnep: return [.loss(path: app.dir + "/loss.out", gnep: true)]
        case .vasp where app.vaspMode == .relax: return [.vaspEnergy(path: app.dir + "/OSZICAR"), .vaspForce(path: app.dir + "/OUTCAR")]
        default: return []
        }
    }

    /// OUTCAR 的力块：表头一行、虚线、每个原子一行（x y z Fx Fy Fz）、虚线。只在读到第二条虚线时输出这一步，
    /// 并用 n= 报告"读完的最后一个完整块"所在的行，正在写的半个块下次重读。
    static let forceAwk = #"awk -v off="$off" '/TOTAL-FORCE/ { inb = 1; d = 0; m = 0; next } inb && /^ *-+ *$/ { d++; if (d == 2) { printf "row=0 %.6g\n", sqrt(m); inb = 0; last = NR } ; next } inb && d == 1 && NF >= 6 { f = $4 * $4 + $5 * $5 + $6 * $6; if (f > m) m = f } END { print "n=" off + last }'"#

    /// 远端脚本：输出 n=总行数，必要时 reset=1，然后是 row= 开头的数据行。
    /// `head -n $((n-off))` 只取 wc 数到的完整行，正在写的半行不读，偏移量才对得上。
    static func script(_ src: Source, offset: Int, head: String) -> String {
        if case .vaspForce = src { return forceScript(src.path, offset: offset, head: head) }
        let filter: String
        switch src {
        case .loss:
            filter = #"awk 'NF >= 2 && $1 ~ /^[0-9]+$/ { print }' | cut -c1-300"#
        case .vaspEnergy, .vaspForce:
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
        sed -n 's/^[[:space:]]*EDIFFG[[:space:]]*=[[:space:]]*\\([-+.0-9eEdD]*\\).*/ediffg=\\1/p' "$(dirname "$f")/INCAR" 2>/dev/null | tail -n 1
        tail -n +$((off + 1)) "$f" | head -n $((n - off)) | \(forceAwk)

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
        for l in lines where l.hasPrefix("row=") {
            let nums = l.dropFirst(4).split(separator: " ").compactMap { Double($0) }
            if nums.count >= 2 { c.rows.append(nums) }
        }
        return c
    }

    static func curve(_ src: Source, rows: [[Double]], extra: [String: String] = [:]) -> AppCurve? {
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
        case .vaspForce:
            // 力块按顺序就是离子步 1、2、3…
            let pts = rows.enumerated().map { CGPoint(x: Double($0.offset + 1), y: max($0.element[1], 1e-6)) }
            // EDIFFG < 0：按力收敛，|EDIFFG| 就是目标（eV/Å）；Fortran 的 d 指数也认。
            let target = extra["ediffg"].flatMap { Double($0.replacingOccurrences(of: "d", with: "e").replacingOccurrences(of: "D", with: "e")) }
                .flatMap { $0 < 0 ? -$0 : nil }
            return AppCurve(title: L("最大力（eV/Å）", "Max force (eV/Å)"), series: [.init(name: "|F|max", points: downsample(pts))],
                            logY: true, xLabel: L("离子步", "ionic step"), threshold: target)
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
            if let c = AppCurves.curve(src, rows: current.rows, extra: current.extra) { out.append(c) }
        }
        return out
    }
}
