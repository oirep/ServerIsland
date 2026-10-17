import SwiftUI

enum IslandMode: Equatable {
    case hidden      // 什么都没有：完全隐藏在硬件刘海里
    case collapsed   // 刘海两侧的小翅膀
    case toast       // 事件提示
    case expanded    // 悬停展开的面板
}

/// 所有尺寸都是确定的（每种行固定高度），这样展开动画可以一次到位，
/// 不需要先渲染再测量。
enum IslandLayout {
    static let wing: CGFloat = 62
    static let expandedMinWidth: CGFloat = 640
    static let toastMinWidth: CGFloat = 420
    static let toastBody: CGFloat = 60
    static let sidePad: CGFloat = 14
    static let topGap: CGFloat = 8
    static let bottomPad: CGFloat = 14
    static let maxContentHeight: CGFloat = 540

    static let cardPad: CGFloat = 12
    static let cardHeader: CGFloat = 20
    static let sectionGap: CGFloat = 10
    static let metricsRow: CGFloat = 16
    static let jobRow: CGFloat = 34
    static let jobGap: CGFloat = 6
    static let moreRow: CGFloat = 14
    static let emptyRow: CGFloat = 16
    static let problemRow: CGFloat = 28
    static let warningRow: CGFloat = 15
    static let cardGap: CGFloat = 8
    static let idleRow: CGFloat = 36
    static let maxJobs = 5
    static let emptyState: CGFloat = 104
    /// 二级页面（详情 / 历史 / 监听）的固定高度。
    static let pageHeight: CGFloat = 420

    struct CardParts: Equatable {
        var metrics = false
        var problem = false
        var connecting = false
        var jobRows = 0
        var more = 0
        var emptyJobs = false
        var warnings = 0
        var paused = false
    }

    static func parts(_ host: HostConfig, _ snap: HostSnapshot) -> CardParts {
        var p = CardParts()
        p.paused = host.paused
        if host.paused && snap.lastUpdate == nil && !snap.isRefreshing { return p }
        if snap.health.isProblem { p.problem = true; return p }
        if snap.lastUpdate == nil { p.connecting = true; return p }
        let m = snap.metrics
        p.metrics = (host.showCPU && m.cpuPercent != nil) || (host.showMemory && m.memoryFraction != nil)
            || (host.showGPU && !snap.gpus.isEmpty)
        p.warnings = snap.warnings.count
        if host.watchJobs || !snap.jobs.isEmpty {
            p.jobRows = min(snap.jobs.count, maxJobs)
            p.more = max(0, snap.jobs.count - maxJobs)
            p.emptyJobs = snap.jobs.isEmpty
        }
        return p
    }

    static func cardHeight(_ p: CardParts) -> CGFloat {
        var h = cardPad * 2 + cardHeader
        if p.paused { h += sectionGap + emptyRow }
        if p.problem { h += sectionGap + problemRow }
        if p.connecting { h += sectionGap + emptyRow }
        if p.metrics { h += sectionGap + metricsRow }
        if p.warnings > 0 { h += 6 + CGFloat(p.warnings) * warningRow }
        if p.jobRows > 0 { h += sectionGap + CGFloat(p.jobRows) * jobRow + CGFloat(p.jobRows - 1) * jobGap }
        if p.more > 0 { h += 4 + moreRow }
        if p.emptyJobs { h += sectionGap + emptyRow }
        return h
    }

    /// 空闲：已连上、没有任务、没有问题和警告、磁盘不紧张。暂停且没有任务的也算。
    static func isIdle(_ host: HostConfig, _ snap: HostSnapshot) -> Bool {
        guard snap.jobs.isEmpty, !snap.health.isProblem, snap.warnings.isEmpty else { return false }
        if snap.lastUpdate == nil { return host.paused && !snap.isRefreshing }
        return !snap.disks.contains { $0.fraction >= 0.8 }
    }

    /// 把机器分成"显示卡片"和"合并成一行的空闲机器"。全部空闲时不合并。
    static func groups(_ hosts: [(HostConfig, HostSnapshot)], fold: Bool)
        -> (cards: [(HostConfig, HostSnapshot)], idle: [(HostConfig, HostSnapshot)]) {
        guard fold else { return (hosts, []) }
        let idle = hosts.filter { isIdle($0.0, $0.1) }
        guard !idle.isEmpty, idle.count < hosts.count else { return (hosts, []) }
        return (hosts.filter { !isIdle($0.0, $0.1) }, idle)
    }

    static func contentHeight(_ hosts: [(HostConfig, HostSnapshot)], fold: Bool = false, showIdle: Bool = false) -> CGFloat {
        guard !hosts.isEmpty else { return emptyState }
        let g = groups(hosts, fold: fold)
        var shown = g.cards
        if showIdle { shown += g.idle }
        var h = shown.map { cardHeight(parts($0.0, $0.1)) }.reduce(0, +) + CGFloat(shown.count - 1) * cardGap
        if !g.idle.isEmpty { h += cardGap + idleRow }
        return h
    }

    @MainActor
    static func wingsVisible(engine: MonitorEngine, style: CollapsedStyle) -> Bool {
        switch style {
        case .always: return !engine.orderedHosts.isEmpty
        case .never: return false
        case .auto: return engine.totalRunning + engine.totalPending > 0 || engine.hasProblem
        }
    }

    @MainActor
    static func mode(hovering: Bool, engine: MonitorEngine, style: CollapsedStyle) -> IslandMode {
        if hovering { return .expanded }
        if engine.currentEvent != nil { return .toast }
        return wingsVisible(engine: engine, style: style) ? .collapsed : .hidden
    }

    struct ShapeSpec: Equatable {
        var size: CGSize
        var topRadius: CGFloat
        var bottomRadius: CGFloat
        var scrolls = false
    }

    static func spec(mode: IslandMode, geometry g: NotchGeometry, contentHeight: CGFloat) -> ShapeSpec {
        let nw = g.notchWidth, nh = g.notchHeight
        switch mode {
        case .hidden:
            let w = max(nw, 1)
            return ShapeSpec(size: CGSize(width: w, height: nh), topRadius: 0, bottomRadius: 8)
        case .collapsed:
            let ear: CGFloat = 6
            return ShapeSpec(size: CGSize(width: nw + 2 * wing + 2 * ear, height: nh), topRadius: ear, bottomRadius: 10)
        case .toast:
            let ear: CGFloat = 10
            let w = max(nw + 2 * 120, toastMinWidth)
            return ShapeSpec(size: CGSize(width: w + 2 * ear, height: nh + toastBody), topRadius: ear, bottomRadius: 22)
        case .expanded:
            let ear: CGFloat = 14
            let w = max(nw + 2 * 200, expandedMinWidth)
            let body = min(contentHeight, maxContentHeight)
            return ShapeSpec(size: CGSize(width: w + 2 * ear, height: nh + topGap + body + bottomPad),
                             topRadius: ear, bottomRadius: 26, scrolls: contentHeight > maxContentHeight)
        }
    }

    /// 面板（NSPanel）的固定尺寸，足以容纳最大展开状态和阴影。
    static func panelSize(_ g: NotchGeometry) -> CGSize {
        let w = max(g.notchWidth + 2 * 200, expandedMinWidth) + 28 + 80
        return CGSize(width: w, height: g.notchHeight + topGap + maxContentHeight + bottomPad + 40)
    }
}
