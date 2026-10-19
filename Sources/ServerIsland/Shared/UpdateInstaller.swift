import AppKit
import CryptoKit
import Foundation

/// 自动更新（Mac）：下载 DMG → 核对 SHA-256（GitHub 给每个附件的 digest）→ 挂载、取出新 App、检查
/// （包名一致、版本号就是要装的版本、签名完整）→ 去掉"从网上下载"的隔离标记 → 交给一个小脚本：
/// 等 ServerIsland 退出后把旧 App 换成新的，再打开新版。任何一步不对都不动旧 App。
enum UpdateInstaller {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    /// 下载和替换用的临时目录（每次更新前清空）。
    static var workDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ServerIsland/Update", isDirectory: true)
    }

    /// 做不到原地替换时返回原因（界面上改为提供下载页面）。
    static func unsupportedReason(_ r: UpdateChecker.Release, bundle: URL = Bundle.main.bundleURL) -> String? {
        guard r.digest != nil, r.downloadURL.pathExtension.lowercased() == "dmg" else {
            return L("这个版本的安装包没有校验信息，请手动下载", "This release has no checksum; please download it manually")
        }
        guard bundle.pathExtension == "app" else {
            return L("开发版本，不自动更新", "Development build; not updating automatically")
        }
        let path = bundle.path
        if path.contains("/AppTranslocation/") || path.hasPrefix("/Volumes/") {
            return L("请先把 ServerIsland 拖到“应用程序”文件夹再更新", "Move ServerIsland to the Applications folder first")
        }
        let parent = bundle.deletingLastPathComponent().path
        guard FileManager.default.isWritableFile(atPath: parent), FileManager.default.isWritableFile(atPath: path) else {
            return L("没有权限替换 \(parent) 里的 App，请手动下载安装", "No permission to replace the app in \(parent); please install it manually")
        }
        return nil
    }

    /// 下载、核对、取出新 App。返回准备好的新 App（在临时目录里）。
    @MainActor
    static func prepare(_ r: UpdateChecker.Release) async throws -> URL {
        let work = workDirectory
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var req = URLRequest(url: r.downloadURL, timeoutInterval: 60)
        req.setValue("ServerIsland/\(UpdateChecker.currentVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw Failure(L("下载失败（HTTP \(code)）", "Download failed (HTTP \(code))")) }
        let dmg = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: tmp, to: dmg)
        return try await Task.detached {
            try stage(dmg: dmg, digest: r.digest ?? "", version: r.version,
                      bundleID: Bundle.main.bundleIdentifier ?? "", into: work)
        }.value
    }

    /// 核对 DMG，挂载并把里面的 App 复制出来，检查后去掉隔离标记。`--test-update` 也直接调用它。
    static func stage(dmg: URL, digest: String, version: String, bundleID: String, into work: URL) throws -> URL {
        guard let actual = sha256(dmg), actual == digest.lowercased() else {
            throw Failure(L("下载的文件校验不对，已放弃更新", "The download failed its checksum; update cancelled"))
        }
        let mount = work.appendingPathComponent("mnt")
        try? FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        guard run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, dmg.path]) == 0 else {
            throw Failure(L("打不开下载的安装包", "Couldn't open the downloaded disk image"))
        }
        defer { _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"]) }
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?.first(where: { $0.hasSuffix(".app") }) else {
            throw Failure(L("安装包里没有 App", "No app found in the disk image"))
        }
        let staged = work.appendingPathComponent("ServerIsland.app")
        guard run("/usr/bin/ditto", [mount.appendingPathComponent(name).path, staged.path]) == 0 else {
            throw Failure(L("复制新版本失败", "Couldn't copy the new version"))
        }
        let info = NSDictionary(contentsOf: staged.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleIdentifier"] as? String == bundleID else {
            throw Failure(L("安装包里的 App 不是 ServerIsland", "The disk image doesn't contain ServerIsland"))
        }
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw Failure(L("安装包的版本号对不上（应为 \(version)）", "The disk image has the wrong version (expected \(version))"))
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path]) == 0 else {
            throw Failure(L("新版本的签名不完整，已放弃更新", "The new version's signature is broken; update cancelled"))
        }
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", staged.path])
        return staged
    }

    /// 写出替换脚本并启动它，然后退出。脚本等这个进程结束后替换 App 并打开新版。
    @MainActor
    static func replaceAndRelaunch(with staged: URL, current: URL = Bundle.main.bundleURL) throws {
        let script = workDirectory.appendingPathComponent("swap.sh")
        try swapScript(pid: getpid(), current: current, staged: staged, relaunch: "/usr/bin/open")
            .write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [script.path]
        try p.run()
        DebugLog.log("自动更新：已准备好新版本，退出后替换 \(current.path)")
        NSApp.terminate(nil)
    }

    /// 等 pid 退出（最多 30 秒）→ 旧 App 改名到同一个文件夹里 → 新 App 移进来（失败时把旧的改回去）→ 打开 → 删掉临时目录。
    static func swapScript(pid: Int32, current: URL, staged: URL, relaunch: String) -> String {
        let q = SSHRunner.shellQuote
        let old = current.deletingLastPathComponent().appendingPathComponent(".ServerIsland-old-\(UUID().uuidString.prefix(8)).app")
        return """
        #!/bin/sh
        # ServerIsland 自动更新：等旧版退出后替换 App，再打开新版。
        CUR=\(q(current.path)); NEW=\(q(staged.path)); OLD=\(q(old.path)); WORK=\(q(staged.deletingLastPathComponent().path))
        i=0
        while kill -0 \(pid) 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
        if mv "$CUR" "$OLD"; then
          if mv "$NEW" "$CUR"; then rm -rf "$OLD"; else mv "$OLD" "$CUR"; fi
        fi
        \(relaunch) "$CUR"
        rm -rf "$WORK"

        """
    }

    static func sha256(_ url: URL) -> String? {
        guard let h = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

// MARK: - `--test-update <目录>`

extension UpdateInstaller {
    /// 在临时目录里走一遍自动更新，不碰真正的 App：造一个 0.3.0 的假 App 打成 DMG → `stage`（校验、挂载、检查）
    /// → 用替换脚本换掉一个 0.2.0 的假 App；另外确认校验值、版本号不对时会拒绝。全部通过时返回 true。
    static func runSelfTest(in dir: URL) -> Bool {
        var ok = true
        func check(_ c: Bool, _ name: String) { print((c ? "✓ " : "✗ ") + name); if !c { ok = false } }
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        let id = "app.serverisland.ServerIsland"
        func fakeApp(at url: URL, version: String) {
            let macos = url.appendingPathComponent("Contents/MacOS")
            try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
            try? fm.copyItem(atPath: "/usr/bin/true", toPath: macos.appendingPathComponent("ServerIsland").path)
            let info: NSDictionary = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version,
                                      "CFBundleExecutable": "ServerIsland", "CFBundlePackageType": "APPL"]
            info.write(to: url.appendingPathComponent("Contents/Info.plist"), atomically: true)
            run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", url.path])
        }
        let src = dir.appendingPathComponent("src")
        fakeApp(at: src.appendingPathComponent("ServerIsland.app"), version: "0.3.0")
        try? "readme".write(to: src.appendingPathComponent("安装说明.txt"), atomically: true, encoding: .utf8)
        let dmg = dir.appendingPathComponent("new.dmg")
        check(run("/usr/bin/hdiutil", ["create", "-volname", "ServerIsland", "-srcfolder", src.path, "-ov", "-format", "UDZO", dmg.path]) == 0,
              "造一个 0.3.0 的 DMG")
        let digest = sha256(dmg) ?? ""
        let current = dir.appendingPathComponent("Applications/ServerIsland.app")
        fakeApp(at: current, version: "0.2.0")

        do {
            _ = try stage(dmg: dmg, digest: String(repeating: "0", count: 64), version: "0.3.0", bundleID: id, into: dir.appendingPathComponent("w1"))
            check(false, "校验值不对时拒绝")
        } catch { check(true, "校验值不对时拒绝：\(error.localizedDescription)") }
        do {
            _ = try stage(dmg: dmg, digest: digest, version: "0.4.0", bundleID: id, into: dir.appendingPathComponent("w2"))
            check(false, "版本号不对时拒绝")
        } catch { check(true, "版本号不对时拒绝：\(error.localizedDescription)") }
        do {
            _ = try stage(dmg: dmg, digest: digest, version: "0.3.0", bundleID: "other.app", into: dir.appendingPathComponent("w3"))
            check(false, "包名不对时拒绝")
        } catch { check(true, "包名不对时拒绝：\(error.localizedDescription)") }

        let work = dir.appendingPathComponent("work")
        guard let staged = try? stage(dmg: dmg, digest: digest, version: "0.3.0", bundleID: id, into: work) else {
            check(false, "取出新 App"); return false
        }
        check(fm.fileExists(atPath: staged.path) && run("/usr/bin/xattr", ["-p", "com.apple.quarantine", staged.path]) != 0,
              "取出新 App（已去掉隔离标记），DMG 已卸载：\(!fm.fileExists(atPath: work.appendingPathComponent("mnt/ServerIsland.app").path))")

        // 替换：脚本要等一个还在运行的进程退出后才动手
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sleep")
        waiter.arguments = ["1"]
        try? waiter.run()
        let script = dir.appendingPathComponent("swap.sh")
        let marker = dir.appendingPathComponent("relaunched")
        try? swapScript(pid: waiter.processIdentifier, current: current, staged: staged,
                        relaunch: "touch \(SSHRunner.shellQuote(marker.path)); test -d")
            .write(to: script, atomically: true, encoding: .utf8)
        let start = Date()
        check(run("/bin/sh", [script.path]) == 0, "运行替换脚本")
        let waited = Date().timeIntervalSince(start)
        let version = NSDictionary(contentsOf: current.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
        let leftovers = (try? fm.contentsOfDirectory(atPath: current.deletingLastPathComponent().path))?.filter { $0.hasPrefix(".ServerIsland-old") } ?? []
        check(waited >= 0.5, String(format: "等旧进程退出后才替换（等了 %.1f 秒）", waited))
        check(version == "0.3.0" && leftovers.isEmpty, "原位置的 App 换成了 0.3.0，旧版已删除")
        check(fm.fileExists(atPath: marker.path) && !fm.fileExists(atPath: work.path), "替换后重新打开，临时目录已清理")
        return ok
    }
}
