import SwiftUI

/// 每个挂载点一个 GPU 风格竖柱；总览数字取最高占比，避免把不同容量磁盘相加误读。
struct DiskColumns: View {
    var disks: [DiskStat]
    @State private var showsCapacity = false

    static func capacityText(_ disk: DiskStat) -> String {
        let totalGB = disk.totalKB / 1_048_576
        let usedGB = disk.usedKB / 1_048_576
        if totalGB >= 1024 {
            return String(format: "%.2f/%.2f TB", usedGB / 1024, totalGB / 1024)
        }
        return String(format: "%.1f/%.1f GB", usedGB, totalGB)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(L("磁盘", "Disk")).font(Theme.rounded(9.5, .semibold)).foregroundStyle(Theme.tertiary)
            HStack(spacing: 3) {
                ForEach(disks.prefix(8)) { disk in
                    let fraction = min(1, max(0, disk.fraction))
                    ZStack(alignment: .bottom) {
                        // 固定总高度的浅灰槽始终可见，填充严格按比例从底部上升。
                        RoundedRectangle(cornerRadius: 2.5).fill(Color.white.opacity(0.24))
                        Rectangle().fill(Theme.load(fraction))
                            .frame(height: 14 * fraction)
                    }
                    .frame(width: 8, height: 14)
                    .clipShape(RoundedRectangle(cornerRadius: 2.5))
                    .overlay(RoundedRectangle(cornerRadius: 2.5).strokeBorder(Color.white.opacity(0.16), lineWidth: 0.5))
                    .help(detail(disk))
                }
            }
            if let disk = disks.max(by: { $0.fraction < $1.fraction }) {
                let prefix = disks.count > 1 ? L("最高 ", "Max ") : ""
                ZStack(alignment: .leading) {
                    Text(prefix + Format.percent(disk.fraction)).hidden()
                    Text(prefix + Self.capacityText(disk)).hidden()
                    Text(prefix + (showsCapacity ? Self.capacityText(disk) : Format.percent(disk.fraction)))
                }
                .font(Theme.rounded(10.5, .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { showsCapacity.toggle() }
        .help(disks.map(detail).joined(separator: "\n"))
    }

    private func detail(_ disk: DiskStat) -> String {
        disk.mount + " · " + Format.percent(disk.fraction) + " · "
            + Format.bytes(disk.usedKB * 1024) + " / " + Format.bytes(disk.totalKB * 1024)
    }
}
