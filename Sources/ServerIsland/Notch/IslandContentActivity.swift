import SwiftUI

private struct IslandContentActiveKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// 保留的隐藏页面仍持有本地视图状态，但不得继续详情高频采集或接收搜索按键。
    var islandContentActive: Bool {
        get { self[IslandContentActiveKey.self] }
        set { self[IslandContentActiveKey.self] = newValue }
    }
}
