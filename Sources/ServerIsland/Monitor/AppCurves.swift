import Foundation

/// 详情页里的小曲线：NEP / GNEP 的 loss，VASP 结构优化每个离子步的能量。
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
}

/// 增量读取的缓存（每台服务器 + 文件一份）。
struct CurveCache {
    var lineCount = 0
    var head = ""
    var rows: [[Double]] = []
}

enum AppCurves {
    static let marker = RemoteScript.marker
    /// 一次最多取这么多行（第一次打开很长的 loss.out 时只取最后这些）。
    static let maxRows = 50_000

    enum Source: Equatable {
        case loss(path: String, gnep: Bool)
        case vaspEnergy(path: String)

        var path: String {
            switch self {
            case .loss(let p, _), .vaspEnergy(let p): return p
            }
        }
    }

    /// 哪些任务有曲线：NEP / GNEP 训练、VASP 结构优化。
    static func source(for app: AppProgress) -> Source? {
        switch app.kind {
        case .nep: return .loss(path: app.dir + "/loss.out", gnep: false)
        case .gnep: return .loss(path: app.dir + "/loss.out", gnep: true)
        case .vasp where app.vaspMode == .relax: return .vaspEnergy(path: app.dir + "/OSZICAR")
        default: return nil
        }
    }

    /// 远端脚本：输出 n=总行数，必要时 reset=1，然后是 row= 开头的数据行。
    /// `head -n $((n-off))` 只取 wc 数到的完整行，正在写的半行不读，偏移量才对得上。
    static func script(_ src: Source, offset: Int, head: String) -> String {
        let filter: String
        switch src {
        case .loss:
            filter = #"awk 'NF >= 2 && $1 ~ /^[0-9]+$/ { print }' | cut -c1-300"#
        case .vaspEnergy:
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

    /// 把一次输出合并进缓存。读不到文件时返回 nil。
    static func merge(_ stdout: String, into cache: CurveCache) -> CurveCache? {
        let lines = stdout.components(separatedBy: "\n")
        if lines.contains(marker + "NOFILE") { return nil }
        guard let n = lines.first(where: { $0.hasPrefix("n=") }).flatMap({ Int($0.dropFirst(2)) }) else { return nil }
        var c = cache
        if lines.contains("reset=1") { c.rows = [] }
        c.lineCount = n
        c.head = lines.first(where: { $0.hasPrefix("head=") }).map { String($0.dropFirst(5)) } ?? ""
        for l in lines where l.hasPrefix("row=") {
            let nums = l.dropFirst(4).split(separator: " ").compactMap { Double($0) }
            if nums.count >= 2 { c.rows.append(nums) }
        }
        return c
    }

    static func curve(_ src: Source, rows: [[Double]]) -> AppCurve? {
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
    /// 读取（增量）任务的曲线。没有曲线、读不到或连接失败时返回 nil。
    func fetchCurve(host: HostConfig, app: AppProgress) async -> AppCurve? {
        guard let src = AppCurves.source(for: app) else { return nil }
        let key = host.id.uuidString + "|" + src.path
        let cache = curveCaches[key] ?? CurveCache()
        let r = await SSHRunner.run(host: host, remoteCommand: host.commands.shell,
                                    script: AppCurves.script(src, offset: cache.lineCount, head: cache.head), timeout: 20)
        guard r.status == 0, let merged = AppCurves.merge(r.stdout, into: cache) else {
            return AppCurves.curve(src, rows: cache.rows)
        }
        curveCaches[key] = merged
        return AppCurves.curve(src, rows: merged.rows)
    }
}
