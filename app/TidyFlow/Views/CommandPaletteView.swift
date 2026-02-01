import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    @FocusState private var inputFocused: Bool

    // Derived data
    var filteredCommands: [Command] {
        guard appState.commandPaletteMode == .command else { return [] }
        let query = appState.commandQuery.lowercased()

        return appState.commands.filter { cmd in
            // Filter by scope
            if cmd.scope == .workspace && appState.selectedWorkspaceKey == nil {
                return false
            }

            // Filter by query
            if query.isEmpty { return true }
            return cmd.title.lowercased().contains(query) ||
                   (cmd.subtitle?.lowercased().contains(query) ?? false)
        }
    }

    var currentFileCache: FileIndexCache? {
        guard let ws = appState.selectedWorkspaceKey else { return nil }
        return appState.fileIndexCache[ws]
    }

    var filteredFiles: [String] {
        guard appState.commandPaletteMode == .file else { return [] }
        guard let ws = appState.selectedWorkspaceKey else { return [] }

        // Get files from cache, fallback to mock if empty
        let cache = appState.fileIndexCache[ws]
        let files: [String]
        if let cache = cache, !cache.items.isEmpty {
            files = cache.items
        } else {
            files = appState.mockFiles[ws] ?? []
        }

        let query = appState.commandQuery.lowercased()
        if query.isEmpty { return files }
        return files.filter { $0.lowercased().contains(query) }
    }

    var fileListState: FileListState {
        guard appState.commandPaletteMode == .file else { return .ready }
        guard appState.selectedWorkspaceKey != nil else { return .noWorkspace }

        if appState.connectionState == .disconnected {
            return .disconnected
        }

        if let cache = currentFileCache {
            if cache.isLoading {
                return .loading
            }
            if let error = cache.error {
                return .error(error)
            }
        }

        return .ready
    }

    enum FileListState {
        case ready
        case loading
        case disconnected
        case noWorkspace
        case error(String)
    }
    
    var resultCount: Int {
        switch appState.commandPaletteMode {
        case .command: return filteredCommands.count
        case .file: return filteredFiles.count
        }
    }
    
    var body: some View {
        ZStack(alignment: .top) {
            // Dimmed background
            Color.black.opacity(0.2)
                .edgesIgnoringSafeArea(.all)
                .onTapGesture {
                    close()
                }
            
            // Palette Window
            VStack(spacing: 0) {
                // Input Area
                HStack {
                    Image(systemName: appState.commandPaletteMode == .command ? "command" : "doc")
                        .foregroundColor(.secondary)
                    
                    TextField(placeholderText, text: $appState.commandQuery)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($inputFocused)
                        .onSubmit {
                            executeSelection()
                        }
                        // Keyboard navigation handling via hidden shortcuts or onChange
                        // Note: List selection via keyboard in SwiftUI is tricky without List focus.
                        // We will use a custom approach: intercept keys if possible, or just rely on global shortcuts for Up/Down if focused.
                        // However, TextField consumes keys.
                        // Solution: Use .onKeyPress (macOS 14+) or just simple "Up/Down" buttons in UI for mouse, 
                        // and try to capture arrows. 
                        // Since we can't easily capture arrows in TextField without wrapping NSView, 
                        // we will use a simpler approach: 
                        // The user types, results update. User uses mouse to click.
                        // OR: We add global keyboard shortcuts for Up/Down that are active only when palette is presented.
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))
                
                Divider()
                
                // Results List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if appState.commandPaletteMode == .file {
                            fileResultsContent
                        } else if resultCount == 0 {
                            Text("No results found")
                                .foregroundColor(.secondary)
                                .padding()
                        } else {
                            resultsList
                        }
                    }
                }
                .frame(maxHeight: 300)
                .background(Color(nsColor: .controlBackgroundColor))
            }
            .frame(width: 600)
            .cornerRadius(10)
            .shadow(radius: 20)
            .padding(.top, 100) // Position from top
        }
        .onAppear {
            inputFocused = true
            // Auto-fetch file index when opening Quick Open
            if appState.commandPaletteMode == .file,
               let ws = appState.selectedWorkspaceKey {
                let cache = appState.fileIndexCache[ws]
                if cache == nil || cache!.isExpired {
                    appState.fetchFileIndex(workspaceKey: ws)
                }
            }
        }
        // Handle ESC to close
        .onExitCommand {
            close()
        }
        // Handle Arrows
        .background(
            Button("") {
                let count = resultCount
                if count > 0 {
                    appState.paletteSelectionIndex = (appState.paletteSelectionIndex - 1 + count) % count
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .hidden()
        )
        .background(
            Button("") {
                let count = resultCount
                if count > 0 {
                    appState.paletteSelectionIndex = (appState.paletteSelectionIndex + 1) % count
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .hidden()
        )
    }
    
    var placeholderText: String {
        switch appState.commandPaletteMode {
        case .command: return "Type a command..."
        case .file: return "Search files by name..."
        }
    }
    
    var resultsList: some View {
        ForEach(0..<resultCount, id: \.self) { index in
            Button {
                appState.paletteSelectionIndex = index
                executeSelection()
            } label: {
                HStack {
                    if appState.commandPaletteMode == .command {
                        renderCommandRow(index: index)
                    } else {
                        renderFileRow(index: index)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(index == appState.paletteSelectionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
    
    func renderCommandRow(index: Int) -> some View {
        let cmd = filteredCommands[index]
        return HStack {
            VStack(alignment: .leading) {
                Text(cmd.title)
                    .font(.headline)
                if let sub = cmd.subtitle {
                    Text(sub)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if let hint = cmd.keyHint {
                Text(hint)
                    .font(.caption)
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
            }
        }
    }
    
    func renderFileRow(index: Int) -> some View {
        let file = filteredFiles[index]
        return HStack {
            Image(systemName: "doc")
            Text(file)
            Spacer()
        }
    }

    @ViewBuilder
    var fileResultsContent: some View {
        switch fileListState {
        case .noWorkspace:
            Text("Select a workspace first")
                .foregroundColor(.secondary)
                .padding()

        case .disconnected:
            HStack {
                Image(systemName: "wifi.slash")
                    .foregroundColor(.red)
                Text("Disconnected from Core")
                    .foregroundColor(.secondary)
            }
            .padding()

        case .loading:
            HStack {
                ProgressView()
                    .scaleEffect(0.7)
                Text("Loading file index...")
                    .foregroundColor(.secondary)
            }
            .padding()

        case .error(let msg):
            HStack {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Text(msg)
                    .foregroundColor(.secondary)
            }
            .padding()

        case .ready:
            if resultCount == 0 {
                Text("No files found")
                    .foregroundColor(.secondary)
                    .padding()
            } else {
                resultsList

                // Show truncated indicator if applicable
                if let cache = currentFileCache, cache.truncated {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Index truncated. Use search to narrow results.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .background(Color.blue.opacity(0.1))
                }
            }
        }
    }

    func close() {
        appState.commandPalettePresented = false
    }
    
    func executeSelection() {
        if appState.commandPaletteMode == .command {
            guard indexIsValid(appState.paletteSelectionIndex, count: filteredCommands.count) else { return }
            let cmd = filteredCommands[appState.paletteSelectionIndex]
            cmd.action(appState)
            close()
        } else {
            guard indexIsValid(appState.paletteSelectionIndex, count: filteredFiles.count) else { return }
            let file = filteredFiles[appState.paletteSelectionIndex]
            if let ws = appState.selectedWorkspaceKey {
                appState.addEditorTab(workspaceKey: ws, path: file)
            }
            close()
        }
    }
    
    func indexIsValid(_ index: Int, count: Int) -> Bool {
        return index >= 0 && index < count
    }
}
