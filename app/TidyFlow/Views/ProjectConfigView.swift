import SwiftUI

/// 项目配置页面 - 在主内容区域显示
struct ProjectConfigView: View {
    let projectName: String
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
    @State private var editingCommand: ProjectCommand?

    /// 当前项目
    private var project: ProjectModel? {
        appState.projects.first(where: { $0.name == projectName })
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题栏
            HStack {
                Image(systemName: "folder.fill")
                    .foregroundColor(.accentColor)
                    .font(.system(size: 20))
                Text(projectName)
                    .font(.title2.bold())
                Spacer()
                Button {
                    appState.selectedProjectForConfig = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("common.close".localized)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .background(.regularMaterial)

            Divider()

            Form {
                if let project = project {
                    Section("projectConfig.info".localized) {
                        HStack {
                            Text("projectConfig.path".localized)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(project.path ?? "—")
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }

                Section {
                    if let project = project, !project.commands.isEmpty {
                        ForEach(project.commands) { cmd in
                            commandRow(cmd)
                        }
                    } else {
                        Text("projectConfig.noCommands.hint".localized)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .listRowBackground(Color.clear)
                    }
                } header: {
                    HStack {
                        Text("projectConfig.commands".localized)
                        Spacer()
                        Button {
                            editingCommand = nil
                            showEditSheet = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .buttonStyle(.borderless)
                        .help("projectConfig.addCommand".localized)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $showEditSheet) {
            if let cmd = editingCommand {
                ProjectCommandEditSheet(
                    command: cmd,
                    isNew: false
                ) { updated in
                    appState.updateProjectCommand(projectName: projectName, updated)
                    editingCommand = nil
                }
            } else {
                ProjectCommandEditSheet(
                    command: ProjectCommand(
                        id: UUID().uuidString,
                        name: "",
                        icon: "terminal",
                        command: "",
                        blocking: false
                    ),
                    isNew: true
                ) { newCmd in
                    appState.addProjectCommand(projectName: projectName, newCmd)
                }
            }
        }
    }

    private func commandRow(_ cmd: ProjectCommand) -> some View {
        HStack(spacing: 12) {
            CommandIconView(iconName: cmd.icon, size: 20)
                .foregroundColor(.accentColor)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(cmd.name)
                        .font(.body)
                    if cmd.blocking {
                        Text("projectConfig.blocking".localized)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                Text(cmd.command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // 编辑按钮
            Button {
                editingCommand = cmd
                showEditSheet = true
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("common.edit".localized)

            // 删除按钮
            Button {
                appState.deleteProjectCommand(projectName: projectName, commandId: cmd.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("common.delete".localized)
        }
        .padding(.vertical, 4)
    }
}
