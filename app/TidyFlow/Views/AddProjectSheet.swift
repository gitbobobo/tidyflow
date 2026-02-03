import SwiftUI
import UniformTypeIdentifiers

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
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Add Project")
                    .font(.headline)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            // Content
            VStack(alignment: .leading, spacing: 16) {
                // Folder Selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project Folder")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    HStack {
                        if let path = selectedPath {
                            Image(systemName: "folder.fill")
                                .foregroundColor(.blue)
                            Text(path.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button("Change") {
                                showFileImporter = true
                            }
                            .buttonStyle(.link)
                        } else {
                            Button(action: { showFileImporter = true }) {
                                HStack {
                                    Image(systemName: "folder.badge.plus")
                                    Text("Select Folder...")
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(12)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }

                // Project Name
                VStack(alignment: .leading, spacing: 8) {
                    Text("Project Name")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    TextField("Enter project name", text: $projectName)
                        .textFieldStyle(.roundedBorder)
                }

                // Error Message
                if let error = importError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(6)
                }

                // Info Note
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundColor(.blue)
                    Text("项目将被导入，默认工作空间指向项目根目录。如需创建独立工作空间，请确保项目已配置 Git 远程仓库。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(8)
                .background(Color.blue.opacity(0.05))
                .cornerRadius(6)
            }
            .padding()

            Spacer()

            Divider()

            // Actions
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(action: importProject) {
                    if isImporting {
                        ProgressView()
                            .scaleEffect(0.7)
                    } else {
                        Text("Import")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedPath == nil || projectName.isEmpty || isImporting)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 380)
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
            print("[AddProjectSheet] Import timeout")
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
                print("[AddProjectSheet] Received project imported: \(result.name)")
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
                print("[AddProjectSheet] Received error: \(errorMsg)")
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

        print("[AddProjectSheet] Sending import request: name=\(trimmedName), path=\(path.path)")
        appState.wsClient.requestImportProject(
            name: trimmedName,
            path: path.path
        )
    }
}
