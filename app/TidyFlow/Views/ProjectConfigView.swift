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

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // 项目信息
                    if let project = project {
                        projectInfoSection(project)
                    }

                    // 命令配置
                    commandsSection
                }
                .padding(24)
            }
        }
        .background(Color(NSColor.windowBackgroundColor))
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

    // MARK: - 项目信息

    private func projectInfoSection(_ project: ProjectModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("projectConfig.info".localized)
                .font(.headline)

            HStack {
                Text("projectConfig.path".localized)
                    .foregroundColor(.secondary)
                Text(project.path ?? "—")
                    .font(.system(size: 13, design: .monospaced))
                    .textSelection(.enabled)
            }
            .font(.system(size: 13))
        }
    }

    // MARK: - 命令配置

    private var commandsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("projectConfig.commands".localized)
                    .font(.headline)
                Spacer()
                Button {
                    editingCommand = nil
                    showEditSheet = true
                } label: {
                    Label("projectConfig.addCommand".localized, systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }

            if let project = project, !project.commands.isEmpty {
                ForEach(project.commands) { cmd in
                    commandRow(cmd)
                }
            } else {
                emptyCommandsView
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
                        .font(.system(size: 14, weight: .medium))
                    if cmd.blocking {
                        Text("projectConfig.blocking".localized)
                            .font(.system(size: 10))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .cornerRadius(4)
                    }
                }
                Text(cmd.command)
                    .font(.system(size: 12, design: .monospaced))
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
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("common.edit".localized)

            // 删除按钮
            Button {
                appState.deleteProjectCommand(projectName: projectName, commandId: cmd.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
            .help("common.delete".localized)
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var emptyCommandsView: some View {
        VStack(spacing: 12) {
            Image(systemName: "terminal")
                .font(.system(size: 32))
                .foregroundColor(.secondary.opacity(0.5))
            Text("projectConfig.noCommands".localized)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text("projectConfig.noCommands.hint".localized)
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.8))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}
