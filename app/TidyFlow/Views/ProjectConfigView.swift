import SwiftUI

struct ProjectConfigView: View {
    @EnvironmentObject var appState: AppState
    @State private var showEditSheet = false
    @State private var editingCommand: ProjectCommand?

    /// 当前项目
    private var project: ProjectModel? {
        appState.projects.first(where: { $0.name == appState.selectedProjectName })
    }

    private var projectName: String {
        project?.name ?? appState.selectedProjectName
    }

    var body: some View {
        VStack(spacing: 0) {
            header

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
                        blocking: false,
                        interactive: false
                    ),
                    isNew: true
                ) { newCmd in
                    appState.addProjectCommand(projectName: projectName, newCmd)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("bottomPanel.category.projectConfig".localized)
                    .font(.system(size: 13, weight: .semibold))
                Text(projectName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            Divider()
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
