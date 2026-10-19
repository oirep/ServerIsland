import Foundation
import SwiftUI

/// 只验证模拟指标和本机脚本，绝不连接真实 Docker daemon 或服务器。
enum SelfTestDocker {
    static func run(_ check: (Bool, String) -> Void) {
        MainActor.assumeIsolated {
            let cell = DockerSearchCell(textCell: "demo 搜索")
            cell.font = .systemFont(ofSize: 11.5)
            cell.isBordered = false; cell.isBezeled = false; cell.usesSingleLineMode = true
            let bounds = NSRect(x: 0, y: 0, width: 140, height: 18)
            let textRect = cell.drawingRect(forBounds: bounds)
            check(abs(textRect.midY - bounds.midY) < 0.01 && textRect.height <= bounds.height,
                  "Docker 搜索布局：原生文字区域在固定输入框内垂直居中")
            let field = DockerSearchInput.makeField()
            field.frame = bounds
            check(field.isEditable && field.isSelectable && field.acceptsFirstResponder,
                  "Docker 搜索焦点：居中 cell 保留可编辑、可选择及首响应能力")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 180, height: 40),
                                  styleMask: .titled, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(field)
            let accepted = window.makeFirstResponder(field)
            let editor = field.currentEditor() as? NSTextView
            editor?.insertText("docker", replacementRange: NSRange(location: NSNotFound, length: 0))
            check(accepted && editor?.string == "docker",
                  "Docker 搜索焦点：隐藏测试窗口可实际建立原生编辑器并输入文字")
            window.makeFirstResponder(nil)
            window.close()
        }
        check(DockerSearchKeyRouting.accepts(characters: "a", modifiers: [], keyCode: 0, hasTextFocus: false, menuTracking: false)
              && DockerSearchKeyRouting.accepts(characters: "中", modifiers: [], keyCode: 0, hasTextFocus: false, menuTracking: false)
              && DockerSearchKeyRouting.accepts(characters: "´", modifiers: [.option], keyCode: 14, hasTextFocus: false, menuTracking: false),
              "Docker 搜索键盘：普通文字、中文和 Option 组合字符可触发聚焦")
        check(!DockerSearchKeyRouting.accepts(characters: "f", modifiers: [.command], keyCode: 3, hasTextFocus: false, menuTracking: false)
              && !DockerSearchKeyRouting.accepts(characters: "a", modifiers: [.control], keyCode: 0, hasTextFocus: false, menuTracking: false),
              "Docker 搜索键盘：不拦截 Command 或 Control 快捷键")
        check(!DockerSearchKeyRouting.accepts(characters: "\u{F702}", modifiers: [], keyCode: 123, hasTextFocus: false, menuTracking: false)
              && !DockerSearchKeyRouting.accepts(characters: "\r", modifiers: [], keyCode: 36, hasTextFocus: false, menuTracking: false)
              && !DockerSearchKeyRouting.accepts(characters: "\u{7f}", modifiers: [], keyCode: 51, hasTextFocus: false, menuTracking: false),
              "Docker 搜索键盘：方向、回车、删除等操作键不会触发文字搜索")
        check(!DockerSearchKeyRouting.accepts(characters: "a", modifiers: [], keyCode: 0, hasTextFocus: true, menuTracking: false)
              && !DockerSearchKeyRouting.accepts(characters: "a", modifiers: [], keyCode: 0, hasTextFocus: false, menuTracking: true),
              "Docker 搜索键盘：已有文本焦点或菜单打开时不重定向")
        let plainLog = DockerLogText.render("普通日志\nnext")
        check(String(plainLog.characters) == "普通日志\nnext" && plainLog.runs.first?.foregroundColor == Theme.secondary,
              "Docker 日志：无颜色日志保持灰色及换行")
        let coloredLog = DockerLogText.render("\u{1b}[31merror\u{1b}[0m normal")
        check(String(coloredLog.characters) == "error normal" && coloredLog.runs.first?.foregroundColor == DockerLogText.palette(1)
              && coloredLog.runs.last?.foregroundColor == Theme.secondary, "Docker 日志：ANSI 前景色与重置正确")
        let extendedLog = DockerLogText.render("\u{1b}[38;5;196mred\u{1b}[38;2;255;0;0m rgb")
        check(String(extendedLog.characters) == "red rgb" && extendedLog.runs.count == 1
              && extendedLog.runs.first?.foregroundColor != Theme.secondary, "Docker 日志：256 色与 RGB 同色合并")
        let safeLog = DockerLogText.render("\u{1b}]8;;https://example.org\u{7}link\u{1b}]8;;\u{7}\u{1b}[2K text\u{1b}[31")
        check(String(safeLog.characters) == "link text", "Docker 日志：隐藏 OSC、光标及截断控制码，保留正文")
        let backgroundLog = DockerLogText.render("\u{1b}[48;2;31;32;33mgray\u{1b}[39m default")
        check(backgroundLog.runs.allSatisfy { $0.foregroundColor == Theme.secondary },
              "Docker 日志：背景色参数不会误改文字颜色")
        let timestampLog = "2026-10-18T12:34:56.123456789Z \u{1b}[31merror\u{1b}[0m\n2026-10-18T12:34:57+08:00 next 2026-10-18T12:34:57Z detail"
        let hiddenTimestamp = DockerLogText.render(timestampLog, showTimestamps: false)
        check(String(hiddenTimestamp.characters) == "error\nnext 2026-10-18T12:34:57Z detail"
              && hiddenTimestamp.runs.first?.foregroundColor == DockerLogText.palette(1),
              "Docker 日志：隐藏每行 Docker 时间戳，保留正文时间与 ANSI 颜色")
        check(String(DockerLogText.render(timestampLog, showTimestamps: true).characters).hasPrefix("2026-10-18T12:34:56.123456789Z "),
              "Docker 日志：开启时间戳后恢复原始前缀")
        let nativeLog = DockerLogText.native(coloredLog)
        check(nativeLog.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == NSColor(DockerLogText.palette(1))
              && nativeLog.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor == NSColor(Theme.secondary),
              "Docker 日志：实际 AppKit 文本属性保留红色及默认灰色")
        let viewport = NSSize(width: 200, height: 100), document = NSSize(width: 800, height: 600)
        check(DockerLogScrollView.position(origin: .zero, viewport: viewport, document: document,
                                           followBottom: true, removedHeight: 0) == NSPoint(x: 0, y: 500),
              "Docker 日志：初次定位在左侧底部，不横向居中")
        check(DockerLogScrollView.position(origin: NSPoint(x: 120, y: 200), viewport: viewport, document: document,
                                           followBottom: false, removedHeight: 0) == NSPoint(x: 120, y: 200),
              "Docker 日志：阅读旧日志时追加数据保留横纵位置")
        check(DockerLogScrollView.position(origin: NSPoint(x: 120, y: 400), viewport: viewport, document: document,
                                           followBottom: true, removedHeight: 0) == NSPoint(x: 120, y: 500),
              "Docker 日志：跟随底部时仍保留用户横向位置")
        check(DockerLogScrollView.removedLines(old: "one\ntwo\nthree\nfour\n", new: "two\nthree\nfour\nfive\n") == 1
              && DockerLogScrollView.position(origin: NSPoint(x: 80, y: 200), viewport: viewport, document: document,
                                              followBottom: false, removedHeight: 14) == NSPoint(x: 80, y: 186),
              "Docker 日志：tail 淘汰旧行后抵消高度，保持正在阅读的行")
        check(Theme.load(0.599) == Theme.mint && Theme.load(0.6) == Theme.cyan
              && Theme.load(0.699) == Theme.cyan && Theme.load(0.7) == Theme.amber
              && Theme.load(0.849) == Theme.amber && Theme.load(0.85) == Theme.coral,
              "资源颜色：60% 青色、70% 黄色、85% 红色，区间边界正确")
        var diskHost = HostConfig(alias: "demo-disk")
        diskHost.showCPU = false; diskHost.showMemory = false; diskHost.watchJobs = false
        var diskSnapshot = HostSnapshot(); diskSnapshot.health = .ok; diskSnapshot.lastUpdate = Date()
        diskSnapshot.disks = [DiskStat(mount: "/", usedKB: 20, totalKB: 100)]
        check(IslandLayout.showsDiskColumns(diskHost, diskSnapshot) && IslandLayout.parts(diskHost, diskSnapshot).metrics,
              "磁盘竖柱：无 GPU 时低占用也显示，且预留指标行高度")
        diskSnapshot.gpus = [GPUStat(index: 0, name: "Demo GPU", utilization: 0, memoryUsedMB: 0, memoryTotalMB: 8192, temperature: nil)]
        check(!IslandLayout.showsDiskColumns(diskHost, diskSnapshot), "磁盘竖柱：显示 GPU 时保留原 GPU 区域")
        diskHost.showGPU = false
        let hiddenGPU = IslandLayout.showsDiskColumns(diskHost, diskSnapshot)
        diskHost.showDisk = false
        check(hiddenGPU && !IslandLayout.showsDiskColumns(diskHost, diskSnapshot), "磁盘竖柱：遵守 GPU 隐藏和磁盘显示开关")
        let diskGB = DiskStat(mount: "/demo-gb", usedKB: 256 * 1_048_576, totalKB: 512 * 1_048_576)
        let diskTB = DiskStat(mount: "/demo-tb", usedKB: 1536 * 1_048_576, totalKB: 2048 * 1_048_576)
        let diskBoundary = DiskStat(mount: "/demo-boundary", usedKB: 512 * 1_048_576, totalKB: 1024 * 1_048_576)
        check(DiskColumns.capacityText(diskGB) == "256.0/512.0 GB"
              && DiskColumns.capacityText(diskTB) == "1.50/2.00 TB"
              && DiskColumns.capacityText(diskBoundary) == "0.50/1.00 TB",
              "磁盘容量：使用 GB/TB 同单位显示已用/总量，并正确处理 TB 边界")
        var host = HostConfig(alias: "demo-docker")
        let legacy = try? JSONDecoder().decode(HostConfig.self, from: Data(#"{"alias":"demo-docker"}"#.utf8))
        check(host.showDocker && RemoteScript.build(for: host).contains("SEC docker"), "Docker：新服务器默认开启 Docker 显示与采集")
        var disabledHost = host; disabledHost.showDocker = false
        let restoredDisabled = (try? JSONEncoder().encode(disabledHost)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(legacy?.showDocker == false && restoredDisabled?.showDocker == false
              && !RemoteScript.build(for: disabledHost).contains("SEC docker"), "Docker：旧配置及显式关闭状态保持不变，不访问 socket")
        let decoded = (try? JSONEncoder().encode(host)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(decoded?.showDocker == true, "Docker：开关可保存并恢复")
        let script = RemoteScript.build(for: host)
        check(script.contains("@@SI:SEC docker") && script.contains(DockerMonitor.source) && script.contains("SI_DOCKER_PY"), "Docker：开关启用后在同一轮询嵌入共享采集器")
        check(DockerMonitor.source.contains("connection.request(\"GET\"") && !DockerMonitor.source.contains("connection.request(\"POST\""), "Docker：采集器只有只读 GET 请求")

        func sample(time: Double, rx: Double, tx: Double, state: String = "running", error: String? = nil) -> [String] {
            var container: [String: Any] = ["id": String(repeating: "a", count: 64), "name": "demo-web", "image": "demo/web:latest",
                "state": state, "status": "Up 5 minutes (healthy)", "health": "healthy", "ports": ["8080/tcp"],
                "composeProject": "demo", "composeService": "web", "cpuPercent": 250.0, "onlineCPUs": 4, "cpuLimitCores": 4.0, "limitsRead": true,
                "memoryUsed": 512.0, "memoryLimit": 1024.0, "networkRx": rx, "networkTx": tx,
                "blockRead": 100.0 + rx, "blockWrite": 200.0 + tx, "pids": 10, "sampledAt": time]
            if let error { container["statsError"] = error }
            let object: [String: Any] = ["containers": [container], "total": 1, "running": 1, "truncated": false, "sampleLimited": false]
            return [String(data: try! JSONSerialization.data(withJSONObject: object), encoding: .utf8)!]
        }
        let first = DockerSnapshot.parse(sample(time: 100, rx: 1000, tx: 2000))
        let next = DockerSnapshot.parse(sample(time: 110, rx: 1500, tx: 3000), previous: first)
        check(first.containers.first?.rxRate == nil && next.containers.first?.rxRate == 50 && next.containers.first?.txRate == 100, "Docker：首次速率未知，后续按真实时间差计算网络吞吐")
        check(next.containers.first?.readRate == 50 && next.containers.first?.writeRate == 100, "Docker：块设备读写速率按计数差计算")
        check(first.containers.first?.cpuUsagePercent == 62.5 && first.containers.first?.cpuFraction == 0.625 && first.containers.first?.memoryFraction == 0.5,
              "Docker：CPU 文字与资源条都按容器限额计算")
        var quota = first.containers[0]; quota.cpuPercent = 107.3; quota.onlineCPUs = 64; quota.cpuLimitCores = nil
        check(quota.cpuUsagePercent == 107.3 && quota.cpuFraction == 1,
              "Docker：未限额 CPU 保留单核读数，107.3% 条形图填满，不被主机核心数稀释")
        quota.cpuLimitCores = 2
        check(abs((quota.cpuUsagePercent ?? 0) - 53.65) < 1e-9 && abs((quota.cpuFraction ?? 0) - 0.5365) < 1e-9,
              "Docker：2 核限额下 107.3% 原始 CPU 显示 53.65%，资源条一致")
        quota.cpuLimitCores = 0.5; quota.cpuPercent = 25
        check(quota.cpuUsagePercent == 50 && quota.cpuFraction == 0.5, "Docker：支持不足一核的容器配额")
        quota.memoryUsed = 512; quota.memoryLimit = 4096; quota.memoryConfiguredLimit = 1024
        check(quota.memoryFraction == 0.5 && quota.memoryCapacity == 1024,
              "Docker：内存按自身 1K 限额计算，不按主机 4K 计算")
        quota.memoryLimit = 512
        check(quota.memoryCapacity == 512 && quota.memoryFraction == 1,
              "Docker：daemon 报告更小有效内存上限时取实际约束")
        let reset = DockerSnapshot.parse(sample(time: 120, rx: 1, tx: 1), previous: next)
        let stopped = DockerSnapshot.parse(sample(time: 120, rx: 2000, tx: 4000, state: "exited"), previous: next)
        let failed = DockerSnapshot.parse(sample(time: 120, rx: 2000, tx: 4000, error: "timeout"), previous: next)
        check(reset.containers.first?.rxRate == nil && stopped.containers.first?.rxRate == nil && failed.containers.first?.rxRate == nil, "Docker：计数回退、停止与采样失败不生成虚假速率")
        let missing = DockerSnapshot.parse(["bash: python3: command not found"])
        check(missing.error == "python_missing" && DockerSnapshot.parse(["bad data"]).error == "invalid_response", "Docker：缺少 Python 与无效响应有独立错误提示")
        var snapshot = HostSnapshot(); snapshot.health = .ok; snapshot.lastUpdate = Date(); snapshot.docker = first
        let parts = IslandLayout.parts(host, snapshot)
        check(parts.docker && parts.dockerRows == 1 && !parts.emptyJobs && !IslandLayout.isIdle(host, snapshot), "Docker：开启监控时显示容器区域，不被折叠为空闲机器")
        let expected = IslandLayout.cardPad * 2 + IslandLayout.cardHeader + IslandLayout.sectionGap + IslandLayout.dockerHeader + IslandLayout.jobGap + IslandLayout.jobRow
        check(IslandLayout.cardHeight(parts) == expected, "Docker：卡片高度包含固定标题和容器行")
        snapshot.docker = DockerSnapshot(error: "permission_denied")
        check(IslandLayout.parts(host, snapshot).dockerRows == 0 && snapshot.health == .ok, "Docker：权限错误不误报整台服务器 SSH 故障")
        host.showDocker = false
        check(!IslandLayout.parts(host, snapshot).docker, "Docker：关闭开关立即隐藏已有容器数据")
        check(legacy?.dockerView == .list && legacy?.dockerAllView == .list && legacy?.dockerSort == .updated, "Docker 展示：旧配置默认为 List 和最新更新")
        let sharedGrid = try? JSONDecoder().decode(HostConfig.self, from: Data(#"{"alias":"demo-docker","dockerView":"grid"}"#.utf8))
        check(sharedGrid?.dockerView == .grid && sharedGrid?.dockerAllView == .grid,
              "Docker 展示：旧版共用 Grid 的配置迁移后保留两个入口的原显示")
        host.showDocker = true; host.dockerView = .grid; host.dockerSort = .memory
        let presentation = (try? JSONEncoder().encode(host)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(presentation?.dockerView == .grid && presentation?.dockerAllView == .list && presentation?.dockerSort == .memory,
              "Docker 展示：首页 Grid 与全部 List 可独立持久保存")
        var older = first.containers[0]; older.id = String(repeating: "b", count: 64); older.createdAt = 10; older.updatedAt = 20; older.cpuPercent = 100; older.memoryUsed = 900
        var newer = first.containers[0]; newer.createdAt = 100; newer.updatedAt = 100; newer.cpuPercent = 250; newer.memoryUsed = 100
        var searchable = newer
        searchable.name = "demo-API"; searchable.image = "registry.example.org/demo:v3"
        searchable.composeProject = "demo-stack"; searchable.composeService = "backend"
        check(DockerContainerSearch.matches(searchable, query: " api ")
              && DockerContainerSearch.matches(searchable, query: String(searchable.id.prefix(8)))
              && DockerContainerSearch.matches(searchable, query: "REGISTRY.EXAMPLE.ORG"),
              "Docker 搜索：名称/ID/镜像部分匹配，忽略大小写与首尾空格")
        check(DockerContainerSearch.matches(searchable, query: "demo-stack backend")
              && DockerContainerSearch.matches(searchable, query: "API v3")
              && !DockerContainerSearch.matches(searchable, query: "API missing"),
              "Docker 搜索：Compose 信息可检索，多词可跨字段匹配且必须全部满足")
        check(DockerContainerSearch.matches(searchable, query: " \n\t")
              && !DockerContainerSearch.matches(searchable, query: "not-found-container"),
              "Docker 搜索：清空查询恢复全部，无结果可显示空状态")
        older.name = "demo-favorite"; newer.name = "demo-newer"
        check(DockerSortOrder.updated.sorted([older, newer]).first?.id == newer.id,
              "Docker 排序：默认按真实变更时间倒序，不按采样时间")
        check(DockerSortOrder.cpu.sorted([older, newer]).first?.id == newer.id
              && DockerSortOrder.memory.sorted([newer, older]).first?.id == older.id
              && DockerSortOrder.resources.sorted([newer, older]).first?.id == older.id, "Docker 排序：CPU、内存和综合资源分别排序，未知值排后")
        let favorites: Set<String> = [older.name]
        check(DockerSortOrder.allCases.allSatisfy { $0.sorted([newer, older], favorites: favorites).first?.id == older.id },
              "Docker 收藏：所有排序方式均优先显示星标容器，首页截取前同样生效")
        var stoppedFavorite = older; stoppedFavorite.state = "exited"
        check(DockerSortOrder.updated.sorted([newer, stoppedFavorite], favorites: favorites).first?.id == stoppedFavorite.id,
              "Docker 收藏：全部列表中已停止收藏项仍位于收藏组，首页继续过滤停止项")
        host.dockerFavorites = [older.name]
        let favoriteConfig = (try? JSONEncoder().encode(host)).flatMap { try? JSONDecoder().decode(HostConfig.self, from: $0) }
        check(legacy?.dockerFavorites == [] && favoriteConfig?.dockerFavorites == [older.name],
              "Docker 收藏：旧配置默认空，星标按服务器和名称持久保存")
        snapshot.docker = first; snapshot.docker?.containers = [newer, older, newer, older]
        let grid = IslandLayout.parts(host, snapshot)
        let gridHeight = IslandLayout.cardPad * 2 + IslandLayout.cardHeader + IslandLayout.sectionGap + IslandLayout.dockerHeader + IslandLayout.jobGap + 2 * IslandLayout.dockerTile + IslandLayout.jobGap
        check(grid.dockerGrid && grid.dockerRows == 2 && IslandLayout.cardHeight(grid) == gridHeight,
              "Docker Grid：双列四项的确定高度与卡片一致")
        var history = DockerHistory()
        let clock = Date(timeIntervalSince1970: 1000)
        var record = first; record.containers[0].sampledAt = 900
        history.record(host: host.id, snapshot: record, now: clock)
        history.record(host: host.id, snapshot: record, now: clock)
        check(history.points(host: host.id, container: newer.id).count == 1, "Docker 时序：重复采样时间不重复累积")
        for step in 1...(DockerHistory.maxPoints + 20) {
            record.containers[0].sampledAt = 900 + Double(step)
            history.record(host: host.id, snapshot: record, now: clock)
        }
        check(history.points(host: host.id, container: newer.id).count == DockerHistory.maxPoints, "Docker 时序：保留最多 600 个样本，覆盖秒级采样的 10 分钟窗口")
        var removed = first; removed.containers = []
        history.record(host: host.id, snapshot: removed, now: clock)
        check(history.points(host: host.id, container: newer.id).isEmpty, "Docker 时序：重建或移除容器不沿用旧 ID 历史")
        check(DockerMonitor.logScript(container: "../../bad;echo test", tail: 200) == nil
              && DockerMonitor.logScript(container: newer.id, tail: 10000)?.contains("SI_DOCKER_LOG_TAIL=200") == true,
              "Docker 日志：拒绝非法容器标识，限制读取尾部行数")
        let errorLogs = try? JSONDecoder().decode(DockerLogs.self, from: Data(#"{"text":"","truncated":false,"error":"logs_unavailable"}"#.utf8))
        check(errorLogs?.error == "logs_unavailable", "Docker 日志：不支持的日志驱动可解析为独立错误")
        let chartPoints = [
            DockerMetricPoint(time: 1000, cpu: 10, memory: 2 * 1_048_576, rx: 2048, tx: 4096, read: 1024, write: 3072),
            DockerMetricPoint(time: 1400, cpu: 20, memory: 3 * 1_048_576, rx: 4096, tx: 8192, read: 2048, write: 6144),
            DockerMetricPoint(time: 1700, cpu: 30, memory: 4 * 1_048_576, rx: 6144, tx: 12288, read: 3072, write: 9216),
        ]
        let firstEnd = DockerChartData.end(points: chartPoints, now: Date(timeIntervalSince1970: 1800))
        let laterEnd = DockerChartData.end(points: chartPoints, now: Date(timeIntervalSince1970: 1801))
        check(laterEnd.timeIntervalSince(firstEnd) == 1,
              "Docker 图表：详情每秒重绘，实时横轴随时钟推进")
        let selector = DockerRangeSelector(selected: 180, labelPrefix: "时间范围 ", onSelect: { _ in })
        let redrawn = DockerRangeSelector(selected: 180, labelPrefix: "时间范围 ", onSelect: { _ in })
        let switched = DockerRangeSelector(selected: 300, labelPrefix: "时间范围 ", onSelect: { _ in })
        check(selector == redrawn && selector != switched,
              "Docker 切换器：页面重绘保持控件等价，选择新范围才更新")
        let liveWindow = DockerChartData.samples(points: chartPoints, metric: .cpu, window: 300, interval: 60, end: laterEnd)
        check(liveWindow.map(\.value) == [30],
              "Docker 图表：秒级重绘时过期数据随实时窗口移出，不补造新采样")
        let shortWindow = DockerChartData.samples(points: chartPoints, metric: .cpu, window: 60, interval: 60)
        let threeMinutes = DockerChartData.samples(points: chartPoints, metric: .cpu, window: 180, interval: 60)
        let fiveMinutes = DockerChartData.samples(points: chartPoints, metric: .cpu, window: 300, interval: 60)
        let longWindow = DockerChartData.samples(points: chartPoints, metric: .cpu, window: 600, interval: 60)
        check(shortWindow.map(\.value) == [30] && threeMinutes.map(\.value) == [30]
              && fiveMinutes.map(\.value) == [20, 30] && longWindow.map(\.value) == [20, 30],
              "Docker 图表：1m/3m/5m/10m 按所选时间窗口过滤实际数据")
        let memorySeries = DockerChartData.samples(points: chartPoints, metric: .memory, window: 1800, interval: 60)
        let networkSeries = DockerChartData.samples(points: chartPoints, metric: .network, window: 1800, interval: 60)
        let ioSeries = DockerChartData.samples(points: chartPoints, metric: .blockIO, window: 1800, interval: 60)
        check(memorySeries.map(\.value) == [2, 3, 4] && networkSeries.filter { $0.series == 1 }.map(\.value) == [4, 8, 12]
              && ioSeries.filter { $0.series == 0 }.map(\.value) == [1, 2, 3] && DockerChartMetric.allCases.count == 4,
              "Docker 四图：CPU、内存、网络和磁盘各自保留独立数据及单位")
        var interrupted = chartPoints
        interrupted[1].cpu = nil
        let segmented = DockerChartData.samples(points: interrupted, metric: .cpu, window: 1800, interval: 60)
        check(Set(segmented.map(\.segment)).count == 2 && segmented.map(\.value) == [10, 30],
              "Docker 图表：缺失和中断的采样不补点或连接为连续曲线")
        check(DockerMonitor.detailScript(container: "../../bad") == nil
              && DockerLivePolling.delay(elapsed: 0.2, failures: 0) == 0.8
              && DockerLivePolling.delay(elapsed: 2, failures: 0) == 0.05,
              "Docker 实时采集：目标 1 秒串行请求，耗时超出时不追赶堆积")
        check(DockerLivePolling.retries("timeout") && DockerLivePolling.retries("ssh")
              && !DockerLivePolling.retries("needs_login") && !DockerLivePolling.retries("logs_unavailable")
              && DockerLivePolling.delay(elapsed: 0, failures: 10) == 15,
              "Docker 实时采集：临时失败自动退避，认证及不支持操作停止重试")
        let fullID = String(repeating: "a", count: 64)
        check(DockerControl.script(container: fullID, action: .restart)?.hasPrefix("SI_DOCKER_CONTROL_CONTAINER=") == true
              && DockerControl.script(container: String(fullID.prefix(12)), action: .stop) == nil
              && DockerControl.script(container: "demo-container", action: .stop) == nil,
              "Docker 控制：仅完整 ID 可生成脚本，拒绝名称和短 ID")
        var terminalHost = HostConfig(alias: "demo-terminal")
        terminalHost.commands.preamble = "export DEMO='value with spaces'"
        if let terminal = DockerControl.terminalScript(host: terminalHost, container: fullID, socket: "/run/user/1000/docker.sock") {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-n"]
            let input = Pipe(); process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try? process.run()
            try? input.fileHandleForWriting.write(contentsOf: Data(terminal.utf8)); try? input.fileHandleForWriting.close()
            process.waitUntilExit()
            check(process.terminationStatus == 0 && terminal.contains("docker exec -it") && !terminal.contains("Terminal.app"),
                  "Docker 终端：交互 SSH 脚本语法有效，不绑定 Terminal.app")
        } else { check(false, "Docker 终端：无法生成交互脚本") }
        let logs200 = DockerControl.logsTerminalScript(host: terminalHost, container: fullID, socket: nil, tail: 200)
        let logs500 = DockerControl.logsTerminalScript(host: terminalHost, container: fullID, socket: nil, tail: 500)
        let noTimestampLogs = DockerControl.logsTerminalScript(host: terminalHost, container: fullID, socket: nil, tail: 500, showTimestamps: false)
        check(noTimestampLogs?.contains("--timestamps") == false && noTimestampLogs?.contains("--tail 500") == true
              && logs500?.contains("--timestamps") == true, "Docker 日志终端：跟随点击时的时间戳开关和行数")
        check(logs200?.contains("--tail 200") == true && logs500?.contains("--tail 500") == true
              && logs500?.contains("--follow") == true && logs500?.contains("docker exec") == false
              && DockerControl.logsTerminalScript(host: terminalHost, container: "demo-name", socket: nil, tail: 500) == nil,
              "Docker 日志终端：按点击时的 200/500 行生成独立跟踪命令，拒绝无效标识")
        var launch = first.containers[0]
        launch.cmd = []; launch.entrypoint = ["/entrypoint", "--serve"]
        check(launch.commandTitle == "ENTRYPOINT" && launch.commandArguments == launch.entrypoint,
              "Docker 命令：未设置 CMD 时回退 ENTRYPOINT")
        launch.cmd = ["server", "--port", "8080"]
        check(launch.commandTitle == "CMD" && launch.commandArguments == launch.cmd,
              "Docker 命令：设置了 CMD 时优先显示 CMD")
        var inactive = first.containers[0]; inactive.id = String(repeating: "c", count: 64)
        inactive.state = "exited"; inactive.updatedAt = 9999999999; inactive.cpuPercent = 99999
        inactive.memoryUsed = 1024; inactive.memoryConfiguredLimit = 1024
        check(DockerSortOrder.allCases.allSatisfy { $0.sorted([inactive, first.containers[0]]).last?.id == inactive.id },
              "Docker 列表：任何排序方式都把停止容器置于最后")
        var home = HostConfig(alias: "demo-home"); home.showDocker = true; home.dockerView = .grid
        var grouped = HostSnapshot(); grouped.health = .ok; grouped.lastUpdate = Date()
        grouped.docker = first; grouped.docker?.containers = [inactive]
        check(IslandLayout.parts(home, grouped).dockerRows == 0,
              "Docker 首页：全部停止时不为停止容器预留行")
        grouped.docker?.containers = [inactive, first.containers[0], first.containers[0], first.containers[0], inactive]
        check(IslandLayout.parts(home, grouped).dockerRows == 2,
              "Docker 首页：Grid 高度只计算活动容器")
        MainActor.assumeIsolated { testLivePolling(check, fixture: first) }
        MainActor.assumeIsolated { testListPolling(check, fixture: first) }
        MainActor.assumeIsolated { testHomePolling(check, fixture: first) }
    }

    /// 以真实计时验证首页立即刷新及三秒节奏，传输全部为本机模拟响应。
    @MainActor
    private static func testHomePolling(_ check: (Bool, String) -> Void, fixture: DockerSnapshot) {
        let host = HostConfig(alias: "demo-home-poll")
        let store = ConfigStore(persist: false); store.settings.hosts = [host]
        let engine = MonitorEngine(store: store)
        var starts: [Date] = [], active = 0, maxActive = 0
        engine.dockerListReader = { _, script in
            starts.append(Date()); active += 1; maxActive = max(maxActive, active)
            defer { active -= 1 }
            try? await Task.sleep(for: .milliseconds(70))
            var list = fixture; list.listOnly = true; list.listedAt = Date().timeIntervalSince1970
            return SSHResult(stdout: String(data: try! JSONEncoder().encode(list), encoding: .utf8)!, stderr: "", status: 0, duration: 0, timedOut: false)
        }
        let opened = Date()
        let home = Task { await engine.monitorDockerList(host: host, interval: 3) { _ in } }
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        check(starts.count == 1 && (starts.first?.timeIntervalSince(opened) ?? 1) < 0.2,
              "Docker 首页：显示后立即快读一次，不等待三秒或全局刷新")
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(starts.count == 1, "Docker 首页：不会沿用全部列表的一秒频率")
        let deadline = opened.addingTimeInterval(4)
        while starts.count < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        home.cancel()
        check(starts.count == 2 && starts[1].timeIntervalSince(starts[0]) >= 2.8,
              "Docker 首页：后续按三秒节奏独立更新")
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
        let beforeManual = starts.count
        var automaticDone = false, manualDone = false
        Task { _ = await engine.refreshDockerList(host: host); automaticDone = true }
        let startDeadline = Date().addingTimeInterval(0.3)
        while engine.dockerListRequests.isEmpty && Date() < startDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        Task { _ = await engine.refreshDockerList(host: host, waitForCurrent: true); manualDone = true }
        let manualDeadline = Date().addingTimeInterval(0.6)
        while !manualDone && Date() < manualDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        check(automaticDone && manualDone && starts.count == beforeManual + 2 && maxActive == 1 && engine.dockerListRequests.isEmpty,
              "Docker 手动刷新：等待自动请求后读取一次，不并发、不被去重吞掉")
    }

    /// 列表使用假传输验证真实生产循环，不连接服务器、Docker daemon 或其它主机。
    @MainActor
    private static func testListPolling(_ check: (Bool, String) -> Void, fixture: DockerSnapshot) {
        let host = HostConfig(alias: "demo-list-only")
        let store = ConfigStore(persist: false); store.settings.hosts = [host]
        store.settings.defaultInterval = 60
        let engine = MonitorEngine(store: store)
        let clock = Date().timeIntervalSince1970
        var initial = fixture; initial.listedAt = clock - 2
        initial.containers[0].sampledAt = clock - 1
        var removed = initial.containers[0]; removed.id = String(repeating: "e", count: 64)
        initial.containers.append(removed); initial.total = 2
        var snapshot = HostSnapshot(); snapshot.docker = initial; snapshot.metrics.cpuPercent = 42
        snapshot.lastUpdate = Date(timeIntervalSince1970: clock - 60)
        snapshot.jobs = [RemoteJob(id: "demo-job", name: "demo", state: .running, source: .process)]
        engine.setSnapshot(snapshot, for: host.id)
        let otherHost = UUID(); var untouched = HostSnapshot(); untouched.metrics.cpuPercent = 99
        engine.setSnapshot(untouched, for: otherHost)
        var calls = 0, updates = 0, scoped = true
        engine.dockerListReader = { selectedHost, script in
            calls += 1
            scoped = scoped && selectedHost.id == host.id && script.hasPrefix("SI_DOCKER_LIST_ONLY=1 ")
            var list = fixture; list.listOnly = true; list.listedAt = clock + Double(calls)
            list.containers[0].sampledAt = nil; list.containers[0].cpuPercent = nil; list.containers[0].memoryUsed = nil
            list.containers[0].status = "Up latest"
            var added = list.containers[0]; added.id = String(repeating: "f", count: 64); added.state = "exited"
            list.containers.append(added); list.total = 2; list.running = 1
            return SSHResult(stdout: String(data: try! JSONEncoder().encode(list), encoding: .utf8)!, stderr: "", status: 0, duration: 0, timedOut: false)
        }
        let task = Task { await engine.monitorDockerList(host: host) { _ in updates += 1 } }
        let deadline = Date().addingTimeInterval(3)
        while updates < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        task.cancel()
        check(calls >= 2 && updates >= 2 && scoped && store.interval(for: host) == 60,
              "Docker 全部列表：全局 1 分钟时独立连续快读，仅请求当前主机列表")
        let current = engine.snapshots[host.id]
        check(current?.docker?.containers.count == 2 && current?.docker?.containers.contains(where: { $0.id == removed.id }) == false
              && current?.docker?.containers.first?.status == "Up latest"
              && current?.docker?.containers.first?.cpuPercent == initial.containers[0].cpuPercent
              && current?.docker?.containers.first?.sampledAt == initial.containers[0].sampledAt,
              "Docker 全部列表：更新增删及状态，保留原资源指标与真实采样时间")
        check(current?.metrics.cpuPercent == 42 && current?.lastUpdate == snapshot.lastUpdate
              && current?.jobs.count == 1 && engine.snapshots[otherHost]?.metrics.cpuPercent == 99,
              "Docker 全部列表：不刷新主机指标、任务、全局时间或其它主机")
        let atClose = calls
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(calls == atClose && engine.dockerListRequests.isEmpty,
              "Docker 全部列表：离开页面取消快读，无遗留刷新请求")
        if var latest = current?.docker {
            latest.containers[0].state = "exited"; latest.running = 0
            var stale = initial; stale.listedAt = clock - 1
            stale.containers[0].sampledAt = clock + 100
            let merged = DockerSnapshot.parse([String(data: try! JSONEncoder().encode(stale), encoding: .utf8)!], previous: latest)
            check(merged.containers.count == latest.containers.count && merged.containers[0].state == "exited"
                  && !merged.containers.contains(where: { $0.id == removed.id }) && merged.listedAt == latest.listedAt,
                  "Docker 全部列表：迟到全局响应不恢复已移除容器或回滚停止状态")
        }
        var entered = false
        engine.dockerListReader = { _, _ in
            entered = true
            try? await Task.sleep(for: .seconds(0.2))
            return SSHResult(stdout: String(data: try! JSONEncoder().encode(fixture), encoding: .utf8)!, stderr: "", status: 0, duration: 0, timedOut: false)
        }
        let late = Task { _ = await engine.refreshDockerList(host: host) }
        let cancelDeadline = Date().addingTimeInterval(0.4)
        while !entered && Date() < cancelDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        var duplicateDone = false
        Task { _ = await engine.refreshDockerList(host: host); duplicateDone = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.04))
        check(duplicateDone, "Docker 全部列表：采集中重复刷新直接返回，不堆积请求")
        late.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))
        check(engine.snapshots[host.id]?.docker == current?.docker && engine.dockerListRequests.isEmpty,
              "Docker 全部列表：页面关闭后丢弃迟到响应并释放刷新状态")
    }

    /// 跑生产采样循环，传输只返回本机假响应，验证快采样与页面退出，不连接 SSH。
    @MainActor
    private static func testLivePolling(_ check: (Bool, String) -> Void, fixture: DockerSnapshot) {
        var host = HostConfig(alias: "demo-live-docker"); host.showDocker = true; host.interval = 60
        let store = ConfigStore(persist: false)
        store.settings.hosts = [host]; store.settings.defaultInterval = 60
        let engine = MonitorEngine(store: store)
        let clock = Date().timeIntervalSince1970
        var initial = fixture
        initial.containers[0].sampledAt = clock - 2
        var other = initial.containers[0]; other.id = String(repeating: "b", count: 64); other.name = "demo-other"
        initial.containers.append(other); initial.total = 2; initial.running = 2
        var snapshot = HostSnapshot(); snapshot.health = .ok; snapshot.docker = initial
        snapshot.metrics.cpuPercent = 42; snapshot.lastUpdate = Date(timeIntervalSince1970: clock - 60)
        snapshot.jobs = [RemoteJob(id: "demo-process", name: "demo", state: .running, source: .process)]
        engine.setSnapshot(snapshot, for: host.id)
        var calls = 0, updates = 0
        var commandIsScoped = true
        engine.dockerDetailReader = { _, script in
            calls += 1
            commandIsScoped = commandIsScoped && script.hasPrefix("SI_DOCKER_DETAIL_CONTAINER=")
            var fresh = fixture
            fresh.containers[0].sampledAt = clock + Double(calls)
            fresh.containers[0].networkRx = 1000 + Double(calls * 100)
            let data = try! JSONEncoder().encode(fresh)
            return SSHResult(stdout: String(data: data, encoding: .utf8)!, stderr: "", status: 0, duration: 0, timedOut: false)
        }
        let task = Task {
            await engine.monitorDockerDetail(host: host, container: fixture.containers[0].id) { _ in updates += 1 }
        }
        let deadline = Date().addingTimeInterval(3)
        while updates < 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        task.cancel()
        check(calls >= 2 && updates >= 2 && commandIsScoped && store.interval(for: host) == 60,
              "Docker 实时采集：全局 1 分钟设置下，详情独立连续取得两个新样本")
        let merged = engine.snapshots[host.id]
        check((merged?.docker?.containers.first?.sampledAt ?? 0) > clock
              && merged?.docker?.containers.count == 2 && merged?.metrics.cpuPercent == 42
              && merged?.lastUpdate == snapshot.lastUpdate && merged?.jobs.count == 1,
              "Docker 实时采集：推进采样时间，保留其它容器和主机指标")
        let countAtClose = calls
        RunLoop.main.run(until: Date().addingTimeInterval(1.1))
        check(calls == countAtClose && engine.dockerLiveRequests.isEmpty,
              "Docker 实时采集：离开详情取消任务后不再采集")
        if let current = engine.snapshots[host.id]?.docker {
            let stale = DockerSnapshot.parse([String(data: try! JSONEncoder().encode(fixture), encoding: .utf8)!], previous: current)
            check(stale.containers[0].sampledAt == current.containers[0].sampledAt,
                  "Docker 实时采集：晚返回的全局旧数据不会回滚新样本")
        }
        var entered = false
        let beforeCancel = engine.snapshots[host.id]?.docker?.containers.first?.sampledAt
        engine.dockerDetailReader = { _, _ in
            entered = true
            try? await Task.sleep(for: .seconds(0.2))
            var fresh = fixture; fresh.containers[0].sampledAt = clock + 999
            return SSHResult(stdout: String(data: try! JSONEncoder().encode(fresh), encoding: .utf8)!, stderr: "", status: 0, duration: 0, timedOut: false)
        }
        let late = Task { _ = await engine.refreshDockerDetail(host: host, container: fixture.containers[0].id) }
        let startDeadline = Date().addingTimeInterval(0.4)
        while !entered && Date() < startDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        late.cancel()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        check(entered && engine.snapshots[host.id]?.docker?.containers.first?.sampledAt == beforeCancel,
              "Docker 实时采集：关闭页面后的迟到响应不写回数据")
        var rejected: String?, checked = false
        Task {
            rejected = await engine.controlDocker(host: host, container: fixture.containers[0].id, action: .stop, confirmed: false)
            checked = true
        }
        let confirmDeadline = Date().addingTimeInterval(0.4)
        while !checked && Date() < confirmDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        check(checked && rejected != nil && engine.dockerControlRequests.isEmpty,
              "Docker 控制：没有用户确认时引擎拒绝启动控制请求")
    }
}
