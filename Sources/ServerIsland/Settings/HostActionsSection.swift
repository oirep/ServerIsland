import SwiftUI

/// 编辑与执行分开：设置页只保存用户输入，刘海上的显式点击才会执行。
struct HostActionsSection: View {
    @Binding var actions: [HostAction]
    @State private var removing: UUID?
    var onRun: (HostAction) -> Void = { _ in }
    var isRunning: (HostAction) -> Bool = { _ in false }

    var body: some View {
        Section {
            ForEach($actions) { $action in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Text(L("名称", "Name"))
                        TextField("", text: $action.name,
                                  prompt: Text(L("例如：部署前端", "e.g. Deploy frontend")))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .frame(minWidth: 100)
                        HStack(spacing: 5) {
                            Text(L("启用", "Enabled")).font(.caption).foregroundStyle(.secondary)
                            Toggle("", isOn: $action.enabled).labelsHidden()
                                .toggleStyle(.switch).controlSize(.small)
                        }.fixedSize()
                        Button { move(action.id, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .buttonStyle(.borderless)
                        .disabled(actions.first?.id == action.id)
                        .help(L("上移", "Move up"))
                        Button { move(action.id, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .buttonStyle(.borderless)
                        .disabled(actions.last?.id == action.id)
                        .help(L("下移", "Move down"))
                        Button { removing = action.id } label: {
                            Image(systemName: "trash").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help(L("移除这个 Action", "Remove this Action"))
                    }
                    Picker(L("执行位置", "Run on"), selection: $action.target) {
                        ForEach(HostAction.Target.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .help(L("本机：填写完整命令。服务器：填写要在这台服务器上执行的 Bash 内容。",
                            "Local: enter the full command. Server: enter the Bash script to run on this host."))
                    HStack {
                        Text(L("执行内容", "Script")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { onRun(action) } label: {
                            Label(isRunning(action) ? L("运行中", "Running") : L("测试执行", "Test run"),
                                  systemImage: isRunning(action) ? "hourglass" : "play.fill")
                        }
                        .controlSize(.small)
                        .disabled(!action.isValid || isRunning(action))
                        .help(L("会实际执行当前填写的命令，并记录进度和日志。", "Runs the current command and records progress and logs."))
                    }
                    ActionCommandEditor(text: $action.command, placeholder: action.target == .local
                        ? "ssh demo-host 'cd /opt/my-app && bash deploy.sh frontend'"
                        : "cd /opt/my-app\nbash deploy.sh frontend")
                }
                .padding(.vertical, 5)
            }
            Button {
                actions.append(HostAction(name: L("新 Action", "New Action")))
            } label: {
                Label(L("添加 Action", "Add Action"), systemImage: "plus.circle.fill")
            }
        } header: {
            SettingsHeader(title: L("Actions", "Actions"), symbol: "play.rectangle.fill", tint: .cyan)
        }
        .confirmationDialog(L("移除这个 Action？", "Remove this Action?"),
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button(L("移除", "Remove"), role: .destructive) {
                    if let id = removing { actions.removeAll { $0.id == id } }
                    removing = nil
                }
        } message: {
            Text(L("只移除快捷配置，不会停止已经启动的任务。", "Only removes the shortcut; running tasks are not stopped."))
        }
    }

    /// 数组顺序就是刘海展示顺序；移动时保留 Action 标识，避免影响正在执行的任务。
    private func move(_ id: UUID, by offset: Int) {
        guard let index = actions.firstIndex(where: { $0.id == id }),
              actions.indices.contains(index + offset) else { return }
        actions.swapAt(index, index + offset)
    }
}
