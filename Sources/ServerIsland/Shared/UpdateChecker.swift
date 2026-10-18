import Foundation

/// 检查更新：读 GitHub 上最新的 Release（`releases/latest`，不含草稿和预发布），和当前版本号比较。
/// 只读一个公开的接口，不上传任何信息；有新版本时提示用户去下载（不自动替换 App）。
@MainActor
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Release: Equatable {
        var version: String
        /// Release 页面。
        var pageURL: URL
        /// 当前平台的安装包（Mac 是 .dmg）；找不到时用 Release 页面。
        var downloadURL: URL
        /// 更新说明的前几行。
        var notes: String
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate(String)
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    static let apiURL = URL(string: "https://api.github.com/repos/zhyan0603/ServerIsland/releases/latest")!

    /// 当前版本（Info.plist）；直接运行调试构建时没有，返回 nil。`--check-update <版本>` 可以假装成某个版本。
    nonisolated(unsafe) static var versionOverride: String?
    static var currentVersion: String? {
        versionOverride ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// 有新版本时返回它。manual：用户点了按钮（失败时也要显示原因）。
    @discardableResult
    func check() async -> Release? {
        guard let current = Self.currentVersion else {
            state = .failed(L("开发版本，不检查更新", "Development build; not checking"))
            return nil
        }
        state = .checking
        var req = URLRequest(url: Self.apiURL, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("ServerIsland/\(current)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            lastChecked = Date()
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                state = .failed(code == 404 ? L("还没有发布任何版本", "No releases yet")
                                : code == 403 ? L("GitHub 暂时限制了访问，请稍后再试", "GitHub rate limit; try again later")
                                : L("GitHub 返回 \(code)", "GitHub returned \(code)"))
                return nil
            }
            guard let r = Self.parse(data, assetSuffix: ".dmg") else {
                state = .failed(L("看不懂 GitHub 的返回", "Unexpected response from GitHub"))
                return nil
            }
            if Self.compare(r.version, current) > 0 {
                state = .available(r)
                DebugLog.log("检查更新：有新版本 \(r.version)（当前 \(current)）")
                return r
            }
            state = .upToDate(r.version)
            return nil
        } catch {
            state = .failed(L("连不上 GitHub：", "Can't reach GitHub: ") + error.localizedDescription)
            return nil
        }
    }

    /// GitHub 的 Release JSON：tag_name（"v0.2.0"）、html_url、assets[].browser_download_url、body。
    nonisolated static func parse(_ data: Data, assetSuffix: String) -> Release? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = obj["tag_name"] as? String,
              let page = (obj["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let version = tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
        let assets = (obj["assets"] as? [[String: Any]]) ?? []
        let download = assets.first { ($0["name"] as? String)?.lowercased().hasSuffix(assetSuffix) == true }
            .flatMap { ($0["browser_download_url"] as? String).flatMap(URL.init(string:)) } ?? page
        let body = (obj["body"] as? String ?? "").replacingOccurrences(of: "\r", with: "")
        return Release(version: version, pageURL: page, downloadURL: download, notes: summary(body))
    }

    /// 更新说明摘要：优先取列表项（- / *），跳过标题、HTML、图片和空行，最多 4 行。
    nonisolated static func summary(_ body: String) -> String {
        let lines = body.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("<") && !$0.hasPrefix("![") && !$0.hasPrefix("---") }
        let bullets = lines.filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }
        return (bullets.isEmpty ? lines : bullets).prefix(4).joined(separator: "\n")
    }

    /// 按数字逐段比较版本号："0.10.0" > "0.9.1"；"0.2" == "0.2.0"；"-beta" 之类的后缀忽略。
    nonisolated static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            s.split(separator: "-").first.map { $0.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 } } ?? []
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p < q ? -1 : 1 }
        }
        return 0
    }
}
