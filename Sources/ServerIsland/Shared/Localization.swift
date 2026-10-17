import Foundation
import SwiftUI

/// 界面语言。
enum AppLanguage: String, Codable, CaseIterable, Identifiable {
    case system, zh, en

    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return L("跟随系统", "Follow System")
        case .zh: return "中文"
        case .en: return "English"
        }
    }
}

enum Lang {
    /// 由 ConfigStore 在启动和修改设置时更新。
    static var setting: AppLanguage = .system

    static var isEnglish: Bool {
        switch setting {
        case .zh: return false
        case .en: return true
        case .system:
            let pref = Locale.preferredLanguages.first ?? "zh"
            return !pref.hasPrefix("zh")
        }
    }
}

/// 中英文成对写在调用处，避免遗漏或错配。
@inline(__always)
func L(_ zh: String, _ en: String) -> String {
    Lang.isEnglish ? en : zh
}

/// 设置项标签：名称后面跟一个小问号，悬停显示解释（代替括号里的说明）。
struct HelpLabel: View {
    var title: String
    var help: String

    init(_ title: String, help: String) {
        self.title = title
        self.help = help
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            if !help.isEmpty {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .help(help)
            }
        }
    }
}
