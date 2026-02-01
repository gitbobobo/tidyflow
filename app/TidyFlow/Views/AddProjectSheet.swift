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
                    Text("The project will be added with a default workspace. You can add more workspaces later.")
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

        // UX-1: For now, create a local mock project
        // TODO: In UX-2, call core import via WS protocol
        let trimmedName = projectName.trimmingCharacters(in: .whitespaces)

        // Check for duplicate name
        if appState.projects.contains(where: { $0.name.lowercased() == trimmedName.lowercased() }) {
            importError = "A project with this name already exists"
            isImporting = false
            return
        }

        // Create project with default workspace
        let defaultWorkspace = WorkspaceModel(name: "default", status: nil)
        let newProject = ProjectModel(
            id: UUID(),
            name: trimmedName,
            path: path.path,
            workspaces: [defaultWorkspace],
            isExpanded: true
        )

        // Add to state
        appState.projects.append(newProject)

        // Auto-select the new workspace
        appState.selectWorkspace(projectId: newProject.id, workspaceName: "default")

        isImporting = false
        dismiss()
    }
}
