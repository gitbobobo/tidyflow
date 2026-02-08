import SwiftUI

struct CommandPaletteView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var fileCache: FileCacheState
    @EnvironmentObject var paletteState: CommandPaletteState
    @FocusState private var inputFocused: Bool

    // Derived data
    var filteredCommands: [Command] {
        guard paletteState.mode == .command else { return [] }
        let query = paletteState.query.lowercased()

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
        return fileCache.fileIndexCache[ws]
    }

    var filteredFiles: [String] {
        guard paletteState.mode == .file else { return [] }
        guard let ws = appState.selectedWorkspaceKey else { return [] }

        // 直接从 fileCache 读取，确保文件索引变化时触发重绘
        let cache = fileCache.fileIndexCache[ws]
        let files: [String]
        if let cache = cache, !cache.items.isEmpty {
            files = cache.items
        } else {
            files = []
        }

        let query = paletteState.query.lowercased()
        if query.isEmpty { return files }
        return files.filter { $0.lowercased().contains(query) }
    }

    var fileListState: FileListState {
        guard paletteState.mode == .file else { return .ready }
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
        switch paletteState.mode {
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
                    Image(systemName: paletteState.mode == .command ? "command" : "doc")
                        .foregroundColor(.secondary)

                    TextField(placeholderText, text: $paletteState.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($inputFocused)
                        .onSubmit {
                            executeSelection()
                        }
                }
                .padding()
                .background(Color(nsColor: .windowBackgroundColor))

                Divider()

                // Results List
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if paletteState.mode == .file {
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
            if paletteState.mode == .file,
               let ws = appState.selectedWorkspaceKey {
                let cache = fileCache.fileIndexCache[ws]
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
                    paletteState.selectionIndex = (paletteState.selectionIndex - 1 + count) % count
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [])
            .hidden()
        )
        .background(
            Button("") {
                let count = resultCount
                if count > 0 {
                    paletteState.selectionIndex = (paletteState.selectionIndex + 1) % count
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [])
            .hidden()
        )
    }

    var placeholderText: String {
        switch paletteState.mode {
        case .command: return "Type a command..."
        case .file: return "Search files by name..."
        }
    }

    var resultsList: some View {
        ForEach(0..<resultCount, id: \.self) { index in
            Button {
                paletteState.selectionIndex = index
                executeSelection()
            } label: {
                HStack {
                    if paletteState.mode == .command {
                        renderCommandRow(index: index)
                    } else {
                        renderFileRow(index: index)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(index == paletteState.selectionIndex ? Color.accentColor.opacity(0.2) : Color.clear)
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
        paletteState.isPresented = false
    }

    func executeSelection() {
        if paletteState.mode == .command {
            guard indexIsValid(paletteState.selectionIndex, count: filteredCommands.count) else { return }
            let cmd = filteredCommands[paletteState.selectionIndex]
            cmd.action(appState)
            close()
        } else {
            guard indexIsValid(paletteState.selectionIndex, count: filteredFiles.count) else { return }
            let file = filteredFiles[paletteState.selectionIndex]
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
