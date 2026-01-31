import SwiftUI
import WebKit

// MARK: - Data Models

struct ProjectInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let root: String
    let workspaceCount: Int
}

struct WorkspaceInfo: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let root: String
    let branch: String
    let status: String
}

// MARK: - Main Content View

struct ContentView: View {
    @State private var connectionStatus: String = "Disconnected"
    @State private var webView: WKWebView?

    // Workspace state
    @State private var projects: [ProjectInfo] = []
    @State private var workspaces: [WorkspaceInfo] = []
    @State private var selectedProject: String? = nil
    @State private var selectedWorkspace: String? = nil
    @State private var currentWorkspaceRoot: String? = nil
    @State private var protocolVersion: Int = 0

    // UI state
    @State private var showWorkspacePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // Status bar with workspace selector
            HStack(spacing: 12) {
                // Connection indicator
                Circle()
                    .fill(connectionStatus == "Connected" ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(connectionStatus)
                    .font(.system(size: 12, weight: .medium))

                Divider()
                    .frame(height: 16)

                // Workspace selector (only show if v1 protocol)
                if protocolVersion >= 1 {
                    workspaceSelector
                }

                Spacer()

                // Current workspace indicator
                if let project = selectedProject, let workspace = selectedWorkspace {
                    Text("\(project)/\(workspace)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Button("Reconnect") {
                    webView?.evaluateJavaScript("window.tidyflow?.reconnect()")
                }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))

            // Terminal WebView
            TerminalWebView(
                connectionStatus: $connectionStatus,
                webView: $webView,
                projects: $projects,
                workspaces: $workspaces,
                selectedProject: $selectedProject,
                selectedWorkspace: $selectedWorkspace,
                currentWorkspaceRoot: $currentWorkspaceRoot,
                protocolVersion: $protocolVersion
            )
        }
        .background(Color.black)
    }

    @ViewBuilder
    private var workspaceSelector: some View {
        // Project picker
        Menu {
            if projects.isEmpty {
                Text("No projects")
                    .foregroundColor(.secondary)
            } else {
                ForEach(projects) { project in
                    Button(action: {
                        selectedProject = project.name
                        // Request workspaces for this project
                        webView?.evaluateJavaScript("window.tidyflow?.listWorkspaces('\(project.name)')")
                    }) {
                        HStack {
                            Text(project.name)
                            if project.name == selectedProject {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Divider()
            Button("Refresh Projects") {
                webView?.evaluateJavaScript("window.tidyflow?.listProjects()")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                Text(selectedProject ?? "Project")
                    .font(.system(size: 11))
            }
        }
        .menuStyle(.borderlessButton)
        .frame(minWidth: 80)

        // Workspace picker (only if project selected)
        if selectedProject != nil {
            Menu {
                if workspaces.isEmpty {
                    Text("No workspaces")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(workspaces) { ws in
                        Button(action: {
                            if let project = selectedProject {
                                selectWorkspace(project: project, workspace: ws.name)
                            }
                        }) {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(ws.name)
                                    Text(ws.branch)
                                        .font(.system(size: 9))
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if ws.name == selectedWorkspace {
                                    Image(systemName: "checkmark")
                                }
                                statusBadge(for: ws.status)
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "square.stack.3d.up")
                    Text(selectedWorkspace ?? "Workspace")
                        .font(.system(size: 11))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 100)
        }
    }

    private func statusBadge(for status: String) -> some View {
        let color: Color
        switch status {
        case "ready":
            color = .green
        case "setup_failed":
            color = .red
        case "creating", "initializing":
            color = .orange
        default:
            color = .gray
        }
        return Circle()
            .fill(color)
            .frame(width: 6, height: 6)
    }

    private func selectWorkspace(project: String, workspace: String) {
        webView?.evaluateJavaScript("window.tidyflow?.selectWorkspace('\(project)', '\(workspace)')")
    }
}

// MARK: - Terminal WebView

struct TerminalWebView: NSViewRepresentable {
    @Binding var connectionStatus: String
    @Binding var webView: WKWebView?
    @Binding var projects: [ProjectInfo]
    @Binding var workspaces: [WorkspaceInfo]
    @Binding var selectedProject: String?
    @Binding var selectedWorkspace: String?
    @Binding var currentWorkspaceRoot: String?
    @Binding var protocolVersion: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        // Allow local file access
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")

        // Set up message handler for Swift-JS communication
        let contentController = WKUserContentController()
        contentController.add(context.coordinator, name: "tidyflow")
        config.userContentController = contentController

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator

        // Load local HTML
        if let htmlURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            webView.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        DispatchQueue.main.async {
            self.webView = webView
        }

        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: TerminalWebView

        init(_ parent: TerminalWebView) {
            self.parent = parent
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            DispatchQueue.main.async {
                switch type {
                case "connected":
                    self.parent.connectionStatus = "Connected"

                case "disconnected":
                    self.parent.connectionStatus = "Disconnected"

                case "error":
                    self.parent.connectionStatus = "Error"

                case "hello":
                    // Protocol version and capabilities
                    if let version = body["version"] as? Int {
                        self.parent.protocolVersion = version
                        // Auto-fetch projects if v1
                        if version >= 1 {
                            self.parent.webView?.evaluateJavaScript("window.tidyflow?.listProjects()")
                        }
                    }

                case "projects":
                    // Update projects list
                    if let items = body["items"] as? [[String: Any]] {
                        self.parent.projects = items.compactMap { item in
                            guard let name = item["name"] as? String,
                                  let root = item["root"] as? String else { return nil }
                            let count = item["workspace_count"] as? Int ?? 0
                            return ProjectInfo(name: name, root: root, workspaceCount: count)
                        }
                    }

                case "workspaces":
                    // Update workspaces list
                    if let items = body["items"] as? [[String: Any]] {
                        self.parent.workspaces = items.compactMap { item in
                            guard let name = item["name"] as? String,
                                  let root = item["root"] as? String,
                                  let branch = item["branch"] as? String,
                                  let status = item["status"] as? String else { return nil }
                            return WorkspaceInfo(name: name, root: root, branch: branch, status: status)
                        }
                    }

                case "workspace_selected":
                    // Workspace switched
                    if let project = body["project"] as? String,
                       let workspace = body["workspace"] as? String,
                       let root = body["root"] as? String {
                        self.parent.selectedProject = project
                        self.parent.selectedWorkspace = workspace
                        self.parent.currentWorkspaceRoot = root
                    }

                case "terminal_spawned":
                    // Terminal spawned with custom cwd
                    if let cwd = body["cwd"] as? String {
                        self.parent.currentWorkspaceRoot = cwd
                    }

                default:
                    break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Inject WebSocket URL from environment or default
            let wsPort = ProcessInfo.processInfo.environment["TIDYFLOW_PORT"] ?? "47999"
            let wsURL = "ws://127.0.0.1:\(wsPort)/ws"
            webView.evaluateJavaScript("window.TIDYFLOW_WS_URL = '\(wsURL)'; window.tidyflow?.connect();")
        }
    }
}

#Preview {
    ContentView()
}
