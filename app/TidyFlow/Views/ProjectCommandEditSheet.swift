import SwiftUI

/// 项目命令编辑弹窗
struct ProjectCommandEditSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var command: ProjectCommand
    let isNew: Bool
    let onSave: (ProjectCommand) -> Void

    @State private var showIconPicker = false

    init(command: ProjectCommand, isNew: Bool, onSave: @escaping (ProjectCommand) -> Void) {
        _command = State(initialValue: command)
        self.isNew = isNew
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    // 图标选择
                    LabeledContent("settings.icon".localized) {
                        Button(action: { showIconPicker = true }) {
                            HStack(spacing: 4) {
                                CommandIconView(iconName: command.icon, size: 16)
                                Text("settings.icon.choose".localized)
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.bordered)
                    }

                    // 名称
                    TextField("settings.name".localized, text: $command.name)
                }

                // 命令内容
                Section("settings.command".localized) {
                    TextEditor(text: $command.command)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.secondary.opacity(0.1), lineWidth: 1)
                        )
                }

                // 阻塞选项
                Section {
                    Toggle(isOn: $command.interactive) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("projectConfig.interactive".localized)
                            Text("projectConfig.interactive.hint".localized)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if !command.interactive {
                        Toggle(isOn: $command.blocking) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("projectConfig.blocking".localized)
                                Text("projectConfig.blocking.hint".localized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            // 底部按钮
            HStack {
                Button("common.cancel".localized) { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(isNew ? "common.add".localized : "common.save".localized) {
                    onSave(command)
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(command.name.isEmpty || command.command.isEmpty)
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 450, height: 420)
        .sheet(isPresented: $showIconPicker) {
            IconPickerSheet(selectedIcon: $command.icon)
        }
    }
}
