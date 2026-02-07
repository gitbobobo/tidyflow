import SwiftUI
import UniformTypeIdentifiers
import os

/// Add Project Sheet - Allows importing a local directory as a project
/// UX-1: Minimal implementation using fileImporter
struct AddProjectSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var projectName: String = ""
    @State private var selectedPath: URL?
    @State private var showFileImporter = false
    @State private var importError: String?
    @State private var isImporting = false

    var body: some View {
        VStack(spacing: 16) {
            // 标题
            Text("addProject.title".localized)
                .font(.headline)

            Form {
                // 项目文件夹
                LabeledContent("addProject.folder".localized) {
                    HStack {
                        if let path = selectedPath {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.accentColor)
                            Text(path.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(path.path)
                            Spacer()
                            Button("addProject.changeFolder".localized) {
                                showFileImporter = true
                            }
                        } else {
                            Button("addProject.selectFolder".localized) {
                                showFileImporter = true
                            }
                        }
                    }
                }

                // 项目名称
                LabeledContent("addProject.name".localized) {
                    TextField("", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .formStyle(.grouped)

            // 错误信息
            if let error = importError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal)
            }

            // 提示信息
            Label {
                Text("addProject.hint".localized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            Divider()

            // 操作按钮
            HStack {
                Button("common.cancel".localized) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: importProject) {
                    if isImporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("addProject.import".localized)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil || projectName.isEmpty || isImporting)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .padding(.top, 16)
        .frame(width: 400, height: 340)
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    // MARK: - Actions

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            if let url = urls.first {
                selectedPath = url
                // Default project name to folder name
                if projectName.isEmpty {
                    projectName = url.lastPathComponent
                }
                importError = nil
            }
        case .failure(let error):
            importError = "Failed to select folder: \(error.localizedDescription)"
        }
    }

    private func importProject() {
        guard let path = selectedPath else { return }
        guard !projectName.trimmingCharacters(in: .whitespaces).isEmpty else {
            importError = "Project name cannot be empty"
            return
        }

        isImporting = true
        importError = nil

        let trimmedName = projectName.trimmingCharacters(in: .whitespaces)

        // Check for duplicate name locally first
        if appState.projects.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
            importError = "A project with this name already exists"
            isImporting = false
            return
        }

        // UX-2: Call backend API to import project
        // Start security-scoped access for the selected path
        let didStartAccess = path.startAccessingSecurityScopedResource()

        // Store previous handlers to restore later
        let previousImportHandler = appState.wsClient.onProjectImported
        let previousErrorHandler = appState.wsClient.onError

        // 使用 @State 绑定来跟踪超时是否已取消
        var timeoutCancelled = false

        // 添加超时保护（30秒，因为大型仓库的 git 操作可能较慢）
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak appState] in
            guard !timeoutCancelled else { return }
            TFLog.app.error("Import timeout for project at path: \(path.path, privacy: .public)")
            if didStartAccess {
                path.stopAccessingSecurityScopedResource()
            }
            appState?.wsClient.onProjectImported = previousImportHandler
            appState?.wsClient.onError = previousErrorHandler
            self.importError = "Import timed out. Please check if the server is running."
            self.isImporting = false
        }

        appState.wsClient.onProjectImported = { [weak appState] result in
            timeoutCancelled = true
            DispatchQueue.main.async {
                if didStartAccess {
                    path.stopAccessingSecurityScopedResource()
                }
                // Restore previous handler
                appState?.wsClient.onProjectImported = previousImportHandler
                appState?.wsClient.onError = previousErrorHandler
                // Handle the result
                appState?.handleProjectImported(result)
                self.isImporting = false
                self.dismiss()
            }
        }

        appState.wsClient.onError = { [weak appState] errorMsg in
            timeoutCancelled = true
            DispatchQueue.main.async {
                if didStartAccess {
                    path.stopAccessingSecurityScopedResource()
                }
                // Restore previous handlers
                appState?.wsClient.onProjectImported = previousImportHandler
                appState?.wsClient.onError = previousErrorHandler
                self.importError = errorMsg
                self.isImporting = false
            }
        }

        appState.wsClient.requestImportProject(
            name: trimmedName,
            path: path.path
        )
    }
}
