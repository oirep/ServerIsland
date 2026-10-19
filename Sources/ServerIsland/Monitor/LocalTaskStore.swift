import Foundation
import Darwin

/// 只读本机当前用户的进度，不连接 SSH，也不把命令或日志发到服务器。
enum LocalTaskStore {
    static var observedExits: [String: Date] = [:]
    struct Record {
        var job: RemoteJob
        var host: String
        var actionID: String
        var updated: Date
        var started: Date
    }
    static var directory: URL {
        let root = ProcessInfo.processInfo.environment["SERVERISLAND_LOCAL_STATE_DIR"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".serverisland")
        return root.appendingPathComponent("local/progress")
    }
    static var localHost: HostConfig {
        var host = HostConfig(alias: "local-tasks", displayName: L("本地任务", "Local tasks"))
        host.id = HostConfig.localTaskID
        host.showCPU = false; host.showMemory = false; host.showGPU = false
        host.showDisk = false; host.watchJobs = false; host.readProgressFiles = false
        return host
    }

    /// 原子文件由包装器写入；限制大小并跳过损坏条目，防止轮询被单个坏文件拖垮。
    static func read(from directory: URL = directory, now: Date = Date()) -> [Record] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .isSymbolicLinkKey])) ?? []
        var records: [Record] = []
        for url in files where url.pathExtension == "json" {
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
                  info.isSymbolicLink != true, let size = info.fileSize, size <= 4096,
                  let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let deployment = obj["deployment"] as? [String: Any],
                  deployment["local"] as? Bool == true,
                  let runID = deployment["run_id"] as? String, UUID(uuidString: runID) != nil
                    || (runID.count == 32 && runID.allSatisfy(\.isHexDigit)),
                  let updated = obj["updated"] as? Double, updated.isFinite,
                  let started = deployment["started"] as? Double, started.isFinite,
                  let name = obj["name"] as? String else { continue }
            let date = Date(timeIntervalSince1970: updated)
            let status = obj["status"] as? String ?? "running"
            var state: JobState = status == "done" ? .completed : status == "failed" ? .failed
                : status == "unknown" ? .other : .running
            var message = obj["message"] as? String ?? ""
            // 进程被 SIGKILL / App 退出后，不会有最终文件；只能标注观察中断，不能编造成功。
            if state == .running, now.timeIntervalSince(date) > 15,
               let pid = deployment["pid"] as? Int,
               (pid <= 0 || (kill(pid_t(clamping: pid), 0) != 0 && errno == ESRCH)) {
                state = .other
                message = L("监控进程已退出，执行结果未知", "Monitor exited; result unknown")
            }
            var job = RemoteJob(id: "local:" + runID, name: name, state: state, source: .progressFile)
            if !state.isActive {
                if status == "running" {
                    // SIGKILL 没有结束时间，以首次确认监控进程消失的时刻开始计时，避免立即被隐藏。
                    let end = observedExits[runID] ?? now
                    observedExits[runID] = end
                    job.progressEndedAt = end
                } else {
                    job.progressEndedAt = (deployment["finished"] as? Double)
                        .flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil } ?? date
                }
            }
            if let p = obj["progress"] as? Double, p.isFinite { job.progress = min(1, max(0, p)) }
            job.message = message
            job.detail = L("本机记录 · ", "Local record · ") + message
            records.append(Record(job: job, host: deployment["host"] as? String ?? "",
                actionID: deployment["action_id"] as? String ?? "", updated: date,
                started: Date(timeIntervalSince1970: started)))
        }
        // 同一任务保留全部运行实例和最近一次结束结果；完整历史仍留在 deployments 目录。
        records.sort { $0.started > $1.started }
        var ended: Set<String> = []
        return records.filter {
            if $0.job.state.isActive { return true }
            return ended.insert($0.host + "|" + ($0.actionID.isEmpty ? $0.job.name : $0.actionID)).inserted
        }
    }
    static func hostID(for record: Record, hosts: [HostConfig]) -> UUID {
        if let host = hosts.first(where: {
            $0.id.uuidString.caseInsensitiveCompare(record.host) == .orderedSame || $0.alias == record.host
        }) { return host.id }
        return HostConfig.localTaskID
    }

    /// 本机任务详情只按经过验证的 run_id 定位文件，不信任日志里的任意路径。
    static func detail(for job: RemoteJob, from directory: URL = directory) -> JobDetail {
        var detail = JobDetail()
        detail.fields = [(L("名称", "Name"), job.name),
                         (L("进度说明", "Progress"), job.message ?? job.state.label)]
        let runID = String(job.id.dropFirst("local:".count))
        guard runID.count == 32, runID.allSatisfy(\.isHexDigit) else { return detail }
        let root = directory.deletingLastPathComponent()
        let metadata = root.appendingPathComponent("deployments/" + runID + ".json")
        var stages: [String] = []
        if let size = try? metadata.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024,
           let data = try? Data(contentsOf: metadata),
           let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let deployment = obj["deployment"] as? [String: Any] {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            formatter.timeZone = .current
            if let started = deployment["started"] as? Double, started.isFinite {
                detail.fields.append((L("开始时间", "Started"), formatter.string(from: Date(timeIntervalSince1970: started))))
            }
            let completed = deployment["finished"] as? Double
                ?? ((obj["status"] as? String) != "running" ? obj["updated"] as? Double : nil)
            if let finished = completed, finished.isFinite {
                detail.fields.append((L("完成时间", "Finished"), formatter.string(from: Date(timeIntervalSince1970: finished))))
            }
            for item in deployment["timeline"] as? [[String: Any]] ?? [] {
                guard let name = item["name"] as? String, let index = item["index"] as? Int,
                      let total = item["total"] as? Int else { continue }
                let elapsed = item["elapsed"] as? Double ?? deployment["stage_elapsed"] as? Double ?? 0
                stages.append("[\(index)/\(total)] \(name) · " + Format.duration(max(0, elapsed)))
            }
        }
        let log = root.appendingPathComponent("logs/" + runID + ".log")
        detail.stdout.path = log.path
        if let handle = try? FileHandle(forReadingFrom: log) {
            defer { try? handle.close() }
            let end = (try? handle.seekToEnd()) ?? 0
            let start = end > 32768 ? end - 32768 : 0
            try? handle.seek(toOffset: start)
            let data = (try? handle.readToEnd()) ?? Data()
            var lines = String(decoding: data, as: UTF8.self).components(separatedBy: .newlines)
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            detail.stdout.lines = Array(lines.suffix(80))
        }
        if !stages.isEmpty {
            detail.stdout.lines = [L("—— 阶段记录 ——", "—— Stages ——")] + stages
                + [L("—— 脚本输出 ——", "—— Script output ——")] + detail.stdout.lines
        }
        if detail.stdout.lines.isEmpty {
            detail.stdout.note = L("等待脚本输出；旧版创建的任务没有保存输出日志。",
                                   "Waiting for output; tasks created by older versions have no saved log.")
        }
        return detail
    }
}
