import SwiftUI

/// 日志匹配配置不含执行命令；保存后由下一次 Action 执行读取快照。
struct ActionLogRuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var rule: ProgressRule
    var onSave: (ProgressRule) -> Void
    var onDelete: () -> Void
    @State private var deleting = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    TextField(L("名称", "Name"), text: $rule.name)
                    Text(L("激活条件（正则，可留空）", "Activation regex (optional)")).font(.caption)
                    ActionCommandEditor(text: $rule.activationPattern, placeholder: "Frontend.*部署脚本")
                    Picker(L("识别方式", "Mode"), selection: $rule.logMode) {
                        Text(L("日志中的阶段编号", "Stage numbers in log")).tag(ProgressRule.LogMode.numbered)
                        Text(L("按顺序匹配阶段标题", "Ordered stage headings")).tag(ProgressRule.LogMode.stages)
                    }.pickerStyle(.segmented)
                }
                if rule.logMode == .numbered {
                    Section {
                        Text(L("日志正则", "Log regex")).font(.caption)
                        ActionCommandEditor(text: $rule.pattern, placeholder: #"^\[进度\s+(\d+)/(\d+)\]\s*(.+)$"#)
                        Stepper(L("当前阶段捕获组：\(rule.currentGroup)", "Current stage group: \(rule.currentGroup)"),
                                value: $rule.currentGroup, in: 1...20)
                        Stepper(L("总阶段捕获组：\(rule.totalGroup)", "Total stages group: \(rule.totalGroup)"),
                                value: $rule.totalGroup, in: 0...20)
                        Stepper(L("阶段名称捕获组：\(rule.labelGroup)", "Stage label group: \(rule.labelGroup)"),
                                value: $rule.labelGroup, in: 0...20)
                        TextField(L("固定总阶段数（可留空）", "Fixed total (optional)"), text: $rule.total)
                        Text(L("固定总数优先于捕获组；名称捕获组为 0 时使用规则名称。", "A fixed total overrides its capture group; label group 0 uses the rule name."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        ForEach($rule.stages) { $stage in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    TextField(L("阶段名称", "Stage name"), text: $stage.name)
                                    Button { move(stage.id, -1) } label: { Image(systemName: "chevron.up") }
                                        .disabled(rule.stages.first?.id == stage.id)
                                    Button { move(stage.id, 1) } label: { Image(systemName: "chevron.down") }
                                        .disabled(rule.stages.last?.id == stage.id)
                                    Button {
                                        rule.stages.removeAll { $0.id == stage.id }
                                    } label: { Image(systemName: "minus.circle") }
                                }
                                ActionCommandEditor(text: $stage.pattern, placeholder: "^开始构建")
                            }
                        }
                        Button(L("添加阶段", "Add stage")) { rule.stages.append(.init()) }
                    } header: { Text(L("阶段顺序就是进度顺序", "Stage order determines progress")) }
                }
                Section {
                    if let problem = rule.problem {
                        Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    }
                    Text(L("激活条件可限定某类脚本；没有激活条件时，只要日志匹配就生效。规则保存后对下次执行生效，不执行任何脚本。",
                           "Activation limits a rule to matching scripts; leave empty to match any output. Changes apply to the next run and never execute scripts."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button(L("删除规则…", "Delete rule…"), role: .destructive) { deleting = true }
                Spacer()
                Button(L("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("保存", "Save")) { onSave(rule); dismiss() }
                    .keyboardShortcut(.defaultAction).disabled(rule.problem != nil)
            }.padding(14)
        }
        .frame(width: 640, height: 620)
        .confirmationDialog(L("删除这条识别规则？", "Delete this detection rule?"), isPresented: $deleting) {
            Button(L("删除", "Delete"), role: .destructive) { onDelete(); dismiss() }
        }
    }
    private func move(_ id: UUID, _ offset: Int) {
        guard let index = rule.stages.firstIndex(where: { $0.id == id }),
              rule.stages.indices.contains(index + offset) else { return }
        rule.stages.swapAt(index, index + offset)
    }
}
