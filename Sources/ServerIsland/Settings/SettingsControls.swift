import ServiceManagement
import SwiftUI

/// 轮询间隔：常用预设 + 自定义秒数（10 秒 ~ 1 小时）。
struct IntervalPicker: View {
    var title: String
    @Binding var seconds: Int?
    /// 为 true 时提供"跟随全局"选项（seconds 可以为 nil）。
    var allowsInherit: Bool
    var inheritedValue: Int = 60

    private static let presets = [15, 30, 60, 120, 300, 600]
    @State private var custom = false
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker(title, selection: selection) {
                if allowsInherit { Text(L("跟随全局（\(Self.label(inheritedValue))）", "Global (\(Self.label(inheritedValue)))")).tag(-1) }
                ForEach(Self.presets, id: \.self) { Text(Self.label($0)).tag($0) }
                Text(L("自定义…", "Custom…")).tag(-2)
            }
            if custom {
                HStack(spacing: 6) {
                    Spacer()
                    TextField(L("秒", "s"), text: $text)
                        .frame(width: 70)
                        .multilineTextAlignment(.trailing)
                        .onSubmit(apply)
                    Text(L("秒", "seconds")).foregroundStyle(.secondary)
                    Button(L("应用", "Apply"), action: apply)
                        .disabled(Int(text) == nil)
                }
                Text(L("范围 10 ~ 3600 秒。", "Range 10 – 3600 s."))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if let s = seconds, !Self.presets.contains(s) { custom = true; text = "\(s)" }
        }
    }

    private var selection: Binding<Int> {
        Binding(
            get: {
                if custom { return -2 }
                guard let s = seconds else { return allowsInherit ? -1 : 60 }
                return Self.presets.contains(s) ? s : -2
            },
            set: { v in
                switch v {
                case -1: custom = false; seconds = nil
                case -2: custom = true; text = "\(seconds ?? inheritedValue)"
                default: custom = false; seconds = v
                }
            })
    }

    private func apply() {
        guard let v = Int(text.trimmingCharacters(in: .whitespaces)) else { return }
        let clamped = min(max(v, 10), 3600)
        seconds = clamped
        text = "\(clamped)"
    }

    static func label(_ s: Int) -> String {
        if s < 60 { return L("\(s) 秒", "\(s) s") }
        if s % 60 == 0 { return L("\(s / 60) 分钟", "\(s / 60) min") }
        return L("\(s / 60) 分 \(s % 60) 秒", "\(s / 60) min \(s % 60) s")
    }
}

/// 登录时启动（SMAppService）。
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(L("登录时自动启动", "Launch at Login"), isOn: Binding(get: { enabled }, set: set))
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange)
            } else if SMAppService.mainApp.status == .requiresApproval {
                Text(L("需要在 系统设置 → 通用 → 登录项 中允许 ServerIsland。", "Allow ServerIsland in System Settings → General → Login Items.")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            error = nil
        } catch {
            self.error = L("设置失败：\(error.localizedDescription)。建议先把 ServerIsland 放进“应用程序”文件夹。", "Failed: \(error.localizedDescription). Try moving ServerIsland to Applications first.")
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

/// 设置页里带彩色图标的分组标题（类似系统设置）。
struct SettingsHeader: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint.gradient))
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary)
        }
        .textCase(nil)
        .padding(.bottom, 2)
    }
}
