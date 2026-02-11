import SwiftUI

@main
struct TidyFlowiOSApp: App {
    @StateObject private var appState = MobileAppState()

    var body: some Scene {
        WindowGroup {
            MobileRootView()
                .environmentObject(appState)
        }
    }
}

struct MobileRootView: View {
    @EnvironmentObject var appState: MobileAppState

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    connectionSection
                    if appState.isConnected {
                        projectSection
                        workspaceSection
                        terminalSection
                    }
                }
                .padding(16)
            }
            .navigationTitle("TidyFlow iOS")
        }
    }

    private var connectionSection: some View {
        GroupBox("连接电脑端") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("地址")
                        .frame(width: 60, alignment: .leading)
                    TextField("如 192.168.1.100", text: $appState.host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("端口")
                        .frame(width: 60, alignment: .leading)
                    TextField("47999", text: $appState.port)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("配对码")
                        .frame(width: 60, alignment: .leading)
                    TextField("6 位数字", text: $appState.pairCode)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                }
                HStack {
                    Text("设备名")
                        .frame(width: 60, alignment: .leading)
                    TextField("iPhone", text: $appState.deviceName)
                        .textFieldStyle(.roundedBorder)
                }

                HStack(spacing: 12) {
                    Button(appState.isConnected ? "断开" : "配对并连接") {
                        if appState.isConnected {
                            appState.disconnect()
                        } else {
                            Task {
                                await appState.pairAndConnect()
                            }
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.connecting)

                    if appState.connecting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                if !appState.connectionMessage.isEmpty {
                    Text(appState.connectionMessage)
                        .font(.caption)
                        .foregroundColor(appState.isConnected ? .green : .secondary)
                }
                if !appState.errorMessage.isEmpty {
                    Text(appState.errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
    }

    private var projectSection: some View {
        GroupBox("项目") {
            VStack(alignment: .leading, spacing: 8) {
                if appState.projects.isEmpty {
                    Text("暂无项目")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.projects, id: \.name) { project in
                        Button {
                            appState.selectProject(project.name)
                        } label: {
                            HStack {
                                Text(project.name)
                                Spacer()
                                if appState.selectedProject == project.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var workspaceSection: some View {
        GroupBox("工作空间") {
            VStack(alignment: .leading, spacing: 8) {
                if appState.selectedProject.isEmpty {
                    Text("先选择一个项目")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else if appState.workspaces.isEmpty {
                    Text("暂无工作空间")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(appState.workspaces, id: \.name) { workspace in
                        Button {
                            appState.selectWorkspace(workspace.name)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name)
                                    Text(workspace.branch)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if appState.selectedWorkspace == workspace.name {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                Button("创建终端") {
                    appState.createTerminalForSelectedWorkspace()
                }
                .buttonStyle(.bordered)
                .disabled(appState.selectedProject.isEmpty || appState.selectedWorkspace.isEmpty)
            }
        }
    }

    private var terminalSection: some View {
        GroupBox("终端") {
            VStack(alignment: .leading, spacing: 8) {
                if !appState.currentTermId.isEmpty {
                    Text("会话: \(appState.currentTermId)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                ScrollView {
                    Text(appState.terminalOutput)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(minHeight: 220)
                .padding(8)
                .background(Color(uiColor: .secondarySystemBackground))
                .cornerRadius(8)

                HStack(spacing: 8) {
                    TextField("输入命令后回车", text: $appState.terminalInput)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            appState.sendTerminalLine()
                        }

                    Button("发送") {
                        appState.sendTerminalLine()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.currentTermId.isEmpty)
                }
            }
        }
    }
}
