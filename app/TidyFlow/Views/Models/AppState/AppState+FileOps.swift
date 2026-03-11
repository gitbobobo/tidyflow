import Foundation
import TidyFlowShared
#if canImport(AppKit)
import AppKit
#endif

extension AppState {
    // MARK: - File Index API

    func handleFileIndexResult(_ result: FileIndexResult) {
        let globalKey = globalWorkspaceKey(
            projectName: result.project,
            workspaceName: result.workspace
        )
        let cache = FileIndexCache(
            items: result.items,
            truncated: result.truncated,
            updatedAt: Date(),
            isLoading: false,
            error: nil
        )
        fileIndexCache[globalKey] = cache
    }

    func fetchFileIndex(workspaceKey: String, cacheMode: HTTPQueryCacheMode = .default) {
        let globalKey = globalWorkspaceKey(
            projectName: selectedProjectName,
            workspaceName: workspaceKey
        )
        guard connectionState == .connected else {
            var cache = fileIndexCache[globalKey] ?? FileIndexCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            fileIndexCache[globalKey] = cache
            return
        }

        // Set loading state
        var cache = fileIndexCache[globalKey] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileIndexCache[globalKey] = cache

        // Send request
        wsClient.requestFileIndex(project: selectedProjectName, workspace: workspaceKey, cacheMode: cacheMode)
    }

    func refreshFileIndex() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchFileIndex(workspaceKey: ws, cacheMode: .forceRefresh)
    }

    func reconnectAndRefresh() {
        wsClient.reconnect()
    }

    // MARK: - v1.22: 文件监控 API

    /// 订阅当前工作空间的文件监控
    func subscribeCurrentWorkspace() {
        guard let workspaceKey = selectedWorkspaceKey else { return }
        wsClient.requestWatchSubscribe(project: selectedProjectName, workspace: workspaceKey)
    }

    /// 取消文件监控订阅
    func unsubscribeWatch() {
        wsClient.requestWatchUnsubscribe()
    }

    /// 使文件缓存失效（收到文件变化通知时调用）
    /// 采用增量更新策略：不清除缓存，直接获取新数据覆盖旧数据，避免界面闪烁
    func invalidateFileCache(project: String, workspace: String) {
        let prefix = WorkspaceKeySemantics.fileCachePrefix(project: project, workspace: workspace)
        let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)

        // 收集所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 清除文件索引缓存（搜索用）
        fileIndexCache.removeValue(forKey: globalKey)

        // 如果是当前选中的工作空间，刷新根目录和所有展开的目录
        // 注意：不清除文件列表缓存，新数据会直接覆盖旧数据
        if workspace == selectedWorkspaceKey && project == selectedProjectName {
            fetchFileList(workspaceKey: workspace, path: ".")
            for path in expandedPaths {
                fetchFileList(workspaceKey: workspace, path: path)
            }
        }
    }

    /// 通知编辑器层文件在磁盘上发生变化
    func notifyEditorFileChanged(notification: FileChangedNotification) {
        let globalKey = globalWorkspaceKey(projectName: notification.project, workspaceName: notification.workspace)
        guard let tabs = workspaceTabs[globalKey] else { return }

        let affectedTabs = tabs.filter { $0.kind == .editor && notification.paths.contains($0.payload) }
        guard !affectedTabs.isEmpty else { return }

        let paths = affectedTabs.map { $0.payload }
        let dirtyFlags = affectedTabs.map { $0.isDirty }
        onEditorFileChanged?(notification.project, notification.workspace, paths, dirtyFlags, notification.kind)

        for tab in affectedTabs {
            updateEditorConflictState(
                workspaceKey: globalKey,
                path: tab.payload,
                kind: notification.kind,
                isDirty: tab.isDirty
            )
        }
    }

    // MARK: - 原生编辑器文档读写

    private func editorRequestKey(project: String, workspace: String, path: String) -> EditorRequestKey {
        EditorRequestKey(project: project, workspace: workspace, path: path)
    }

    private func contentHash(_ content: String) -> Int {
        content.hashValue
    }

    func getEditorDocument(globalWorkspaceKey: String, path: String) -> EditorDocumentState? {
        editorDocumentsByWorkspace[globalWorkspaceKey]?[path]
    }

    func updateEditorDocumentContent(globalWorkspaceKey: String, path: String, content: String) {
        guard var workspaceDocs = editorDocumentsByWorkspace[globalWorkspaceKey],
              var doc = workspaceDocs[path] else { return }
        doc.content = content
        doc.isDirty = contentHash(content) != doc.originalContentHash
        doc.conflictState = .none
        workspaceDocs[path] = doc
        editorDocumentsByWorkspace[globalWorkspaceKey] = workspaceDocs
        updateEditorDirtyState(path: path, isDirty: doc.isDirty)
    }

    func reloadEditorDocument(project: String, workspace: String, path: String) {
        openEditorDocument(project: project, workspace: workspace, path: path, force: true)
    }

    func openEditorDocument(project: String, workspace: String, path: String, force: Bool = false) {
        let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        var workspaceDocs = editorDocumentsByWorkspace[globalKey] ?? [:]
        if !force, let existing = workspaceDocs[path], existing.status == .ready {
            return
        }
        workspaceDocs[path] = .loading(path: path)
        editorDocumentsByWorkspace[globalKey] = workspaceDocs

        let key = editorRequestKey(project: project, workspace: workspace, path: path)
        pendingFileReadRequests.insert(key)
        wsClient.requestFileRead(
            project: project,
            workspace: workspace,
            path: path,
            cacheMode: force ? .forceRefresh : .default
        )
    }

    func saveEditorDocument(project: String, workspace: String, path: String) {
        let globalKey = globalWorkspaceKey(projectName: project, workspaceName: workspace)
        guard let doc = getEditorDocument(globalWorkspaceKey: globalKey, path: path) else { return }

        lastEditorPath = path
        editorStatus = "Saving..."
        editorStatusIsError = false
        let key = editorRequestKey(project: project, workspace: workspace, path: path)
        pendingFileWriteRequests.insert(key)
        let data = Data(doc.content.utf8)
        wsClient.requestFileWrite(project: project, workspace: workspace, path: path, content: data)
    }

    func handleFileReadResult(_ result: FileReadResult) {
        if let pendingPath = pendingEvolutionPlanDocumentReadPath, pendingPath == result.path {
            pendingEvolutionPlanDocumentReadPath = nil
            evolutionPlanDocumentLoading = false
            let content = String(decoding: result.content, as: UTF8.self)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                evolutionPlanDocumentError = "evolution.page.planDocument.empty".localized
                evolutionPlanDocumentContent = nil
            } else {
                evolutionPlanDocumentError = nil
                evolutionPlanDocumentContent = content
            }
            return
        }

        let key = editorRequestKey(project: result.project, workspace: result.workspace, path: result.path)

        guard pendingFileReadRequests.contains(key) else {
            return
        }
        pendingFileReadRequests.remove(key)

        let content = String(decoding: result.content, as: UTF8.self)
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        var workspaceDocs = editorDocumentsByWorkspace[globalKey] ?? [:]
        workspaceDocs[result.path] = EditorDocumentState(
            path: result.path,
            content: content,
            originalContentHash: contentHash(content),
            isDirty: false,
            lastLoadedAt: Date(),
            status: .ready,
            conflictState: .none
        )
        editorDocumentsByWorkspace[globalKey] = workspaceDocs
        updateEditorDirtyState(path: result.path, isDirty: false)
    }

    private func updateEditorConflictState(workspaceKey: String, path: String, kind: String, isDirty: Bool) {
        guard var workspaceDocs = editorDocumentsByWorkspace[workspaceKey],
              var doc = workspaceDocs[path] else { return }

        if kind == "delete" {
            doc.conflictState = .deletedOnDisk
            workspaceDocs[path] = doc
            editorDocumentsByWorkspace[workspaceKey] = workspaceDocs
            return
        }

        if isDirty {
            doc.conflictState = .changedOnDisk
            workspaceDocs[path] = doc
            editorDocumentsByWorkspace[workspaceKey] = workspaceDocs
            return
        }

        let parts = workspaceKey.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return }
        openEditorDocument(project: parts[0], workspace: parts[1], path: path, force: true)
    }

    // MARK: - 文件列表 API

    /// 生成文件列表缓存键（包含项目名称以区分不同项目的同名工作空间）
    private func fileListCacheKey(project: String, workspace: String, path: String) -> String {
        return WorkspaceKeySemantics.fileCacheKey(project: project, workspace: workspace, path: path)
    }

    /// 处理文件列表结果
    func handleFileListResult(_ result: FileListResult) {
        let key = fileListCacheKey(project: result.project, workspace: result.workspace, path: result.path)
        let cache = FileListCache(
            items: result.items,
            isLoading: false,
            error: nil,
            updatedAt: Date()
        )
        fileListCache[key] = cache
    }

    /// 获取目录文件列表
    /// - Parameters:
    ///   - project: 项目名称；必须与当前 `selectedProjectName` 语义一致。
    ///              显式传入可避免异步回调中 `selectedProjectName` 已切换导致的缓存键错位。
    ///   - workspaceKey: 工作区名称
    ///   - path: 目录路径，默认为根目录 "."
    func fetchFileList(
        project: String,
        workspaceKey: String,
        path: String = ".",
        cacheMode: HTTPQueryCacheMode = .default
    ) {
        let key = fileListCacheKey(project: project, workspace: workspaceKey, path: path)

        // 性能追踪：文件树请求
        let perfEvent: TFPerformanceEvent = path == "." ? .fileTreeRequest : .fileTreeExpand
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: perfEvent,
            project: project,
            workspace: workspaceKey,
            metadata: ["path": path]
        ))

        guard connectionState == .connected else {
            var cache = fileListCache[key] ?? FileListCache.empty()
            cache.error = "connection.disconnected".localized
            cache.isLoading = false
            fileListCache[key] = cache
            performanceTracer.end(perfTraceId)
            return
        }

        let now = Date()
        if let lastSentAt = fileListRequestLastSentAt[key],
           now.timeIntervalSince(lastSentAt) < 0.35,
           fileListCache[key]?.isLoading == true {
            performanceTracer.end(perfTraceId)
            return
        }

        // 设置加载状态
        var cache = fileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileListCache[key] = cache
        fileListRequestLastSentAt[key] = now

        // 发送请求（追踪 ID 随请求上下文传递，handleFileListResult 中结束追踪）
        wsClient.requestFileList(project: project, workspace: workspaceKey, path: path, cacheMode: cacheMode)
        // 请求发出即视为本轮追踪结束（实际网络延迟在 Core 端日志体现）
        performanceTracer.end(perfTraceId)
    }

    /// 获取目录文件列表（便捷重载，隐式使用当前 `selectedProjectName`）。
    /// 调用方须保证 `selectedProjectName` 在调用前已设置为目标项目，否则请使用显式 `project:` 重载。
    func fetchFileList(workspaceKey: String, path: String = ".", cacheMode: HTTPQueryCacheMode = .default) {
        fetchFileList(project: selectedProjectName, workspaceKey: workspaceKey, path: path, cacheMode: cacheMode)
    }

    /// 获取缓存的文件列表
    func getFileListCache(project: String, workspaceKey: String, path: String) -> FileListCache? {
        let key = fileListCacheKey(project: project, workspace: workspaceKey, path: path)
        return fileListCache[key]
    }

    /// 获取缓存的文件列表
    func getFileListCache(workspaceKey: String, path: String) -> FileListCache? {
        getFileListCache(project: selectedProjectName, workspaceKey: workspaceKey, path: path)
    }

    /// 刷新当前工作空间的文件列表（包括根目录和所有展开的目录）
    /// 仅刷新当前 project/workspace 下的路径，避免跨项目同名工作区串扰。
    func refreshFileList() {
        guard let ws = selectedWorkspaceKey else { return }
        let project = selectedProjectName
        let prefix = WorkspaceKeySemantics.fileCachePrefix(project: project, workspace: ws)
        let perfTraceId = performanceTracer.begin(TFPerformanceContext(
            event: .workspaceTreeRefresh,
            project: project,
            workspace: ws,
            metadata: ["scope": "expanded_paths"]
        ))

        // 收集当前工作区下所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 根目录始终刷新
        fetchFileList(project: project, workspaceKey: ws, path: ".", cacheMode: .forceRefresh)
        // 展开的目录增量刷新（跳过根目录避免重复请求）
        for path in expandedPaths where path != "." {
            fetchFileList(project: project, workspaceKey: ws, path: path, cacheMode: .forceRefresh)
        }
        performanceTracer.end(perfTraceId)
    }

    /// 切换目录展开状态
    func toggleDirectoryExpanded(project: String, workspaceKey: String, path: String) {
        let key = fileListCacheKey(project: project, workspace: workspaceKey, path: path)
        let currentState = directoryExpandState[key] ?? false
        directoryExpandState[key] = !currentState

        // 如果展开，且没有缓存或缓存已过期，则请求文件列表
        if !currentState {
            let cache = fileListCache[key]
            if cache == nil || cache!.isExpired {
                fetchFileList(project: project, workspaceKey: workspaceKey, path: path)
            }
        }
    }

    /// 切换目录展开状态
    func toggleDirectoryExpanded(workspaceKey: String, path: String) {
        toggleDirectoryExpanded(project: selectedProjectName, workspaceKey: workspaceKey, path: path)
    }

    /// 检查目录是否展开
    func isDirectoryExpanded(workspaceKey: String, path: String) -> Bool {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        return directoryExpandState[key] ?? false
    }

    /// 处理文件重命名结果
    func handleFileRenameResult(_ result: FileRenameResult) {
        if result.success {
            // 刷新文件列表
            refreshFileList()
            // 如果重命名的文件正在编辑器中打开，更新标签
            updateEditorTabAfterRename(oldPath: result.oldPath, newPath: result.newPath)
        } else {
            TFLog.app.error("文件重命名失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }

    /// 处理文件删除结果
    func handleFileDeleteResult(_ result: FileDeleteResult) {
        if result.success {
            // 刷新文件列表
            refreshFileList()
            // 如果删除的文件正在编辑器中打开，关闭标签
            closeEditorTabAfterDelete(path: result.path)
        } else {
            TFLog.app.error("文件删除失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }

    /// 请求重命名文件或目录
    func renameFile(workspaceKey: String, path: String, newName: String) {
        guard connectionState == .connected else {
            TFLog.app.warning("无法重命名：未连接")
            return
        }
        wsClient.requestFileRename(
            project: selectedProjectName,
            workspace: workspaceKey,
            oldPath: path,
            newName: newName
        )
    }

    /// 请求删除文件或目录（移到回收站）
    func deleteFile(workspaceKey: String, path: String) {
        guard connectionState == .connected else {
            TFLog.app.warning("无法删除：未连接")
            return
        }
        wsClient.requestFileDelete(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: path
        )
    }

    /// v1.25: 请求移动文件或目录到新目录
    func moveFile(workspaceKey: String, oldPath: String, newDir: String) {
        guard connectionState == .connected else {
            TFLog.app.warning("无法移动：未连接")
            return
        }
        wsClient.requestFileMove(
            project: selectedProjectName,
            workspace: workspaceKey,
            oldPath: oldPath,
            newDir: newDir
        )
    }

    /// 处理文件移动结果
    func handleFileMoveResult(_ result: FileMoveResult) {
        if result.success {
            refreshFileList()
            updateEditorTabAfterRename(oldPath: result.oldPath, newPath: result.newPath)
        } else {
            TFLog.app.error("文件移动失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }

    // MARK: - 新建文件

    /// 请求新建文件
    func createNewFile(workspaceKey: String, parentDir: String, fileName: String) {
        guard connectionState == .connected else {
            TFLog.app.warning("无法新建文件：未连接")
            return
        }
        // 拼接路径
        let filePath = parentDir == "." ? fileName : "\(parentDir)/\(fileName)"
        // 检查文件列表缓存中是否已有同名文件
        let cacheKey = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: parentDir)
        if let cache = fileListCache[cacheKey] {
            if cache.items.contains(where: { $0.name == fileName }) {
                return
            }
        }
        wsClient.requestFileWrite(
            project: selectedProjectName,
            workspace: workspaceKey,
            path: filePath,
            content: Data()
        )
    }

    /// 处理文件写入结果
    func handleFileWriteResult(_ result: FileWriteResult) {
        let key = editorRequestKey(project: result.project, workspace: result.workspace, path: result.path)
        if pendingFileWriteRequests.contains(key) {
            pendingFileWriteRequests.remove(key)
            handleEditorFileWriteResult(result)
            return
        }

        if result.success {
            refreshFileList()
        } else {
            TFLog.app.error("新建文件失败: \(result.path, privacy: .public)")
        }
    }

    private func handleEditorFileWriteResult(_ result: FileWriteResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)
        if result.success {
            if var workspaceDocs = editorDocumentsByWorkspace[globalKey],
               var doc = workspaceDocs[result.path] {
                doc.originalContentHash = contentHash(doc.content)
                doc.isDirty = false
                doc.lastLoadedAt = Date()
                doc.status = .ready
                doc.conflictState = .none
                workspaceDocs[result.path] = doc
                editorDocumentsByWorkspace[globalKey] = workspaceDocs
            }
            handleEditorSaved(path: result.path)
            refreshFileList()
        } else {
            handleEditorSaveError(path: result.path, message: "保存失败")
        }
    }

    /// 重命名后更新编辑器标签
    private func updateEditorTabAfterRename(oldPath: String, newPath: String) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard var tabs = workspaceTabs[globalKey] else { return }
        // 检查是否有打开的编辑器标签匹配旧路径
        if let index = tabs.firstIndex(where: { $0.kind == .editor && $0.payload == oldPath }) {
            // 更新标签路径（payload）和标题
            tabs[index].payload = newPath
            let newFileName = String(newPath.split(separator: "/").last ?? Substring(newPath))
            tabs[index].title = newFileName
            workspaceTabs[globalKey] = tabs
        }
    }

    /// 删除后关闭编辑器标签
    private func closeEditorTabAfterDelete(path: String) {
        guard let globalKey = currentGlobalWorkspaceKey else { return }
        guard let tabs = workspaceTabs[globalKey] else { return }
        // 检查是否有打开的编辑器标签匹配路径（包括子路径，因为可能删除的是目录）
        let tabsToClose = tabs.filter { tab in
            tab.kind == .editor && (tab.payload == path || tab.payload.hasPrefix(path + "/"))
        }

        for tab in tabsToClose {
            performCloseTab(workspaceKey: globalKey, tabId: tab.id)
        }
    }

    // MARK: - v1.24: 文件复制粘贴（使用系统剪贴板）

    /// 复制文件到系统剪贴板（Finder 兼容格式）
    func copyFileToClipboard(workspaceKey: String, path: String, isDir: Bool, name: String) {
        #if canImport(AppKit)
        guard let workspacePath = selectedWorkspacePath else {
            return
        }
        let absolutePath = (workspacePath as NSString).appendingPathComponent(path)
        let fileURL = URL(fileURLWithPath: absolutePath)

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        clipboardHasFiles = true
        #endif
    }

    /// 从系统剪贴板读取文件 URL 列表
    private func readFileURLsFromClipboard() -> [URL] {
        #if canImport(AppKit)
        let pasteboard = NSPasteboard.general
        // 优先使用 urlReadingFileURLsOnly 确保只读取文件 URL
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL], !urls.isEmpty {
            return urls
        }
        // 兜底：从 pasteboardItems 中直接读取 public.file-url
        var result: [URL] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let urlString = item.string(forType: .fileURL),
               let url = URL(string: urlString),
               url.isFileURL {
                result.append(url)
            }
        }
        return result
        #else
        return []
        #endif
    }

    /// 从系统剪贴板粘贴文件到指定目录
    func pasteFiles(workspaceKey: String, destDir: String) {
        guard connectionState == .connected else {
            return
        }

        let urls = readFileURLsFromClipboard()
        guard !urls.isEmpty else {
            return
        }

        for url in urls {
            let absolutePath = url.path
            wsClient.requestFileCopy(
                destProject: selectedProjectName,
                destWorkspace: workspaceKey,
                sourceAbsolutePath: absolutePath,
                destDir: destDir
            )
        }
    }

    /// 检查系统剪贴板是否有文件（同时同步 clipboardHasFiles 状态）
    func checkClipboardForFiles() {
        clipboardHasFiles = !readFileURLsFromClipboard().isEmpty
    }

    /// 处理文件复制结果
    func handleFileCopyResult(_ result: FileCopyResult) {
        if result.success {
            // 使用响应中的 project 字段，而非 selectedProjectName，
            // 避免异步返回时项目已切换导致刷新错误项目的缓存。
            let destDir = (result.destPath as NSString).deletingLastPathComponent
            let refreshPath = destDir.isEmpty ? "." : destDir
            fetchFileList(project: result.project, workspaceKey: result.workspace, path: refreshPath)
        } else {
            TFLog.app.error("文件复制失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }
}
