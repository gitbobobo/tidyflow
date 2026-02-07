import Foundation
#if canImport(AppKit)
import AppKit
#endif

extension AppState {
    // MARK: - File Index API

    func fetchFileIndex(workspaceKey: String) {
        guard connectionState == .connected else {
            var cache = fileIndexCache[workspaceKey] ?? FileIndexCache.empty()
            cache.error = "Disconnected"
            cache.isLoading = false
            fileIndexCache[workspaceKey] = cache
            return
        }

        // Set loading state
        var cache = fileIndexCache[workspaceKey] ?? FileIndexCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileIndexCache[workspaceKey] = cache

        // Send request
        wsClient.requestFileIndex(project: selectedProjectName, workspace: workspaceKey)
    }

    func refreshFileIndex() {
        guard let ws = selectedWorkspaceKey else { return }
        fetchFileIndex(workspaceKey: ws)
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
        let prefix = "\(project):\(workspace):"

        // 收集所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 清除文件索引缓存（搜索用）
        fileIndexCache.removeValue(forKey: workspace)

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
    }

    // MARK: - 文件列表 API

    /// 生成文件列表缓存键（包含项目名称以区分不同项目的同名工作空间）
    private func fileListCacheKey(project: String, workspace: String, path: String) -> String {
        return "\(project):\(workspace):\(path)"
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
    func fetchFileList(workspaceKey: String, path: String = ".") {
        let projectName = selectedProjectName
        let key = fileListCacheKey(project: projectName, workspace: workspaceKey, path: path)
        
        guard connectionState == .connected else {
            var cache = fileListCache[key] ?? FileListCache.empty()
            cache.error = "connection.disconnected".localized
            cache.isLoading = false
            fileListCache[key] = cache
            return
        }

        // 设置加载状态
        var cache = fileListCache[key] ?? FileListCache.empty()
        cache.isLoading = true
        cache.error = nil
        fileListCache[key] = cache

        // 发送请求
        wsClient.requestFileList(project: projectName, workspace: workspaceKey, path: path)
    }

    /// 获取缓存的文件列表
    func getFileListCache(workspaceKey: String, path: String) -> FileListCache? {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        return fileListCache[key]
    }

    /// 刷新当前工作空间的文件列表（包括根目录和所有展开的目录）
    func refreshFileList() {
        guard let ws = selectedWorkspaceKey else { return }
        let prefix = "\(selectedProjectName):\(ws):"

        // 收集所有展开的目录路径
        let expandedPaths = directoryExpandState
            .filter { $0.key.hasPrefix(prefix) && $0.value }
            .map { String($0.key.dropFirst(prefix.count)) }

        // 刷新根目录和所有展开的目录
        fetchFileList(workspaceKey: ws, path: ".")
        for path in expandedPaths {
            fetchFileList(workspaceKey: ws, path: path)
        }
    }

    /// 切换目录展开状态
    func toggleDirectoryExpanded(workspaceKey: String, path: String) {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        let currentState = directoryExpandState[key] ?? false
        directoryExpandState[key] = !currentState
        
        // 如果展开，且没有缓存或缓存已过期，则请求文件列表
        if !currentState {
            let cache = fileListCache[key]
            if cache == nil || cache!.isExpired {
                fetchFileList(workspaceKey: workspaceKey, path: path)
            }
        }
    }

    /// 检查目录是否展开
    func isDirectoryExpanded(workspaceKey: String, path: String) -> Bool {
        let key = fileListCacheKey(project: selectedProjectName, workspace: workspaceKey, path: path)
        return directoryExpandState[key] ?? false
    }

    // MARK: - v1.23: File Rename/Delete API

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
        if result.success {
            refreshFileList()
        } else {
            TFLog.app.error("新建文件失败: \(result.path, privacy: .public)")
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
            // 刷新目标目录的文件列表
            let destDir = (result.destPath as NSString).deletingLastPathComponent
            let refreshPath = destDir.isEmpty ? "." : destDir
            fetchFileList(workspaceKey: result.workspace, path: refreshPath)
        } else {
            TFLog.app.error("文件复制失败: \(result.message ?? "未知错误", privacy: .public)")
        }
    }
}
