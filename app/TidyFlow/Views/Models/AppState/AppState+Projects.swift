import Foundation

extension AppState {
    // MARK: - UX-2: Project Import API

    /// Handle projects list result from WebSocket
    func handleProjectsList(_ result: ProjectsListResult) {
        let oldProjects = self.projects
        
        self.projects = result.items.map { info in
            let oldProject = oldProjects.first(where: { $0.path == info.root })
            
            return ProjectModel(
                id: oldProject?.id ?? UUID(),
                name: info.name,
                path: info.root,
                workspaces: oldProject?.workspaces ?? [], // Keep old workspaces while loading
                isExpanded: oldProject?.isExpanded ?? true,
                commands: info.commands
            )
        }

        // Request workspaces for each project
        for project in result.items {
            wsClient.requestListWorkspaces(project: project.name)
        }
    }

    /// Handle workspaces list result from WebSocket
    func handleWorkspacesList(_ result: WorkspacesListResult) {
        if let index = projects.firstIndex(where: { $0.name == result.project }) {
            // 服务端现在会返回 "default" 虚拟工作空间，将其标记为 isDefault
            let newWorkspaces = result.items.map { item in
                WorkspaceModel(
                    name: item.name,
                    root: item.root,
                    status: item.status,
                    isDefault: item.name == "default"
                )
            }
            
            projects[index].workspaces = newWorkspaces
        }
    }

    /// Handle project imported result from WebSocket
    func handleProjectImported(_ result: ProjectImportedResult) {
        projectImportInFlight = false
        projectImportError = nil

        // 创建默认工作空间（虚拟，指向项目根目录）
        let defaultWs = WorkspaceModel(
            name: "default",
            root: result.root,
            status: "ready",
            isDefault: true
        )

        let newProject = ProjectModel(
            id: UUID(),
            name: result.name,
            path: result.root,
            workspaces: [defaultWs],
            isExpanded: true
        )

        // Add to state
        projects.append(newProject)

        // 自动选中默认工作空间
        selectWorkspace(projectId: newProject.id, workspaceName: defaultWs.name)
    }

    /// Handle workspace created result from WebSocket
    func handleWorkspaceCreated(_ result: WorkspaceCreatedResult) {
        // Find the project and add the workspace
        if let index = projects.firstIndex(where: { $0.name == result.project }) {
            let newWorkspace = WorkspaceModel(
                name: result.workspace.name,
                root: result.workspace.root,
                status: result.workspace.status,
                isDefault: false
            )
            projects[index].workspaces.append(newWorkspace)

            // Auto-select the new workspace
            selectWorkspace(projectId: projects[index].id, workspaceName: result.workspace.name)
        }
    }

    /// Handle workspace removed result from WebSocket
    func handleWorkspaceRemoved(_ result: WorkspaceRemovedResult) {
        let globalKey = globalWorkspaceKey(projectName: result.project, workspaceName: result.workspace)

        // 移除删除中标记
        deletingWorkspaces.remove(globalKey)

        if result.ok {
            if let index = projects.firstIndex(where: { $0.name == result.project }) {
                projects[index].workspaces.removeAll { $0.name == result.workspace }
                if selectedWorkspaceKey == result.workspace {
                    selectedWorkspaceKey = projects[index].workspaces.first?.name
                }
            }
            // 清理残留缓存
            workspaceTabs.removeValue(forKey: globalKey)
            activeTabIdByWorkspace.removeValue(forKey: globalKey)
            fileIndexCache.removeValue(forKey: globalKey)
            workspaceTerminalOpenTime.removeValue(forKey: globalKey)
        }
    }

    /// Import a project from local path
    func importProject(name: String, path: String) {
        guard connectionState == .connected else {
            projectImportError = "Disconnected"
            return
        }

        projectImportInFlight = true
        projectImportError = nil

        wsClient.requestImportProject(
            name: name,
            path: path
        )
    }

    /// 移除项目
    func removeProject(id: UUID) {
        guard let project = projects.first(where: { $0.id == id }) else { return }
        guard connectionState == .connected else { return }

        // 先从 UI 移除
        projects.removeAll { $0.id == id }

        // 发送请求到 Core 进行持久化移除
        wsClient.requestRemoveProject(name: project.name)
    }

    /// Create a new workspace in a project（名称由 Core 用 petname 生成）
    func createWorkspace(projectName: String, fromBranch: String? = nil) {
        guard connectionState == .connected else { return }

        wsClient.requestCreateWorkspace(project: projectName, fromBranch: fromBranch)
    }

    /// Remove a workspace from a project
    func removeWorkspace(projectName: String, workspaceName: String) {
        guard connectionState == .connected else { return }
        let globalKey = globalWorkspaceKey(projectName: projectName, workspaceName: workspaceName)

        // 标记为删除中
        deletingWorkspaces.insert(globalKey)

        // 如果当前选中的就是要删除的工作空间，先切换到其他工作空间
        if selectedWorkspaceKey == workspaceName,
           let project = projects.first(where: { $0.name == projectName }),
           let other = project.workspaces.first(where: { $0.name != workspaceName }) {
            selectWorkspace(projectId: project.id, workspaceName: other.name)
        }

        // 强制关闭所有 tab（含终端 kill）
        forceCloseAllTabs(workspaceKey: globalKey)

        // 取消所有后台任务
        taskManager.cancelAllTasks(for: globalKey)

        // 发送删除请求
        wsClient.requestRemoveWorkspace(project: projectName, workspace: workspaceName)
    }

    /// 在指定编辑器中打开路径（项目根或工作空间根）
    func openPathInEditor(_ path: String, editor: ExternalEditor) -> Bool {
        #if canImport(AppKit)
        guard editor.isInstalled else {
            return false
        }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        task.arguments = ["-b", editor.bundleId, path]
        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus != 0 {
                return false
            }
            return true
        } catch {
            TFLog.app.error("启动 \(editor.rawValue, privacy: .public) 失败: \(error.localizedDescription, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    func setupCommands() {
        self.commands = [
            Command(id: "global.palette", title: "Show Command Palette", subtitle: nil, scope: .global, keyHint: "Cmd+Shift+P") { app in
                app.commandPaletteMode = .command
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.quickOpen", title: "Quick Open", subtitle: "Go to file", scope: .global, keyHint: "Cmd+P") { app in
                app.commandPaletteMode = .file
                app.commandPalettePresented = true
                app.commandQuery = ""
                app.paletteSelectionIndex = 0
            },
            Command(id: "global.toggleExplorer", title: "Show Explorer", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .explorer
            },
            Command(id: "global.toggleSearch", title: "Show Search", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .search
            },
            Command(id: "global.toggleGit", title: "Show Git", subtitle: nil, scope: .global, keyHint: nil) { app in
                app.activeRightTool = .git
            },
            Command(id: "global.reconnect", title: "Reconnect", subtitle: "Restart Core and reconnect", scope: .global, keyHint: "Cmd+R") { app in
                app.restartCore()
            },
            Command(id: "workspace.refreshFileIndex", title: "Refresh File Index", subtitle: "Reload file list from Core", scope: .workspace, keyHint: nil) { app in
                app.refreshFileIndex()
            },
            Command(id: "workspace.newTerminal", title: "New Terminal", subtitle: nil, scope: .workspace, keyHint: "Cmd+T") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.addTerminalTab(workspaceKey: ws)
            },
            Command(id: "workspace.closeTab", title: "Close Active Tab", subtitle: nil, scope: .workspace, keyHint: "Cmd+W") { app in
                guard let ws = app.currentGlobalWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeTab(workspaceKey: ws, tabId: tabId)
            },
            Command(id: "workspace.closeOtherTabs", title: "Close Other Tabs", subtitle: nil, scope: .workspace, keyHint: "Opt+Cmd+T") { app in
                guard let ws = app.currentGlobalWorkspaceKey,
                      let tabId = app.activeTabIdByWorkspace[ws] else { return }
                app.closeOtherTabs(workspaceKey: ws, keepTabId: tabId)
            },
            Command(id: "workspace.closeSavedTabs", title: "Close Saved Tabs", subtitle: nil, scope: .workspace, keyHint: "Cmd+K Cmd+U") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.closeSavedTabs(workspaceKey: ws)
            },
            Command(id: "workspace.closeAllTabs", title: "Close All Tabs", subtitle: nil, scope: .workspace, keyHint: "Cmd+K Cmd+W") { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.closeAllTabs(workspaceKey: ws)
            },
            Command(id: "workspace.nextTab", title: "Next Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Tab") { app in
                app.nextTab()
            },
            Command(id: "workspace.prevTab", title: "Previous Tab", subtitle: nil, scope: .workspace, keyHint: "Ctrl+Shift+Tab") { app in
                app.prevTab()
            },
            Command(id: "workspace.save", title: "Save File", subtitle: nil, scope: .workspace, keyHint: "Cmd+S") { app in
                 app.saveActiveEditorFile()
            },
            // UX-3a: Git rebase commands
            Command(id: "git.fetch", title: "Git: Fetch", subtitle: "Fetch from remote", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitFetch(workspaceKey: ws)
            },
            Command(id: "git.rebase", title: "Git: Rebase onto Default Branch", subtitle: "Rebase onto origin/main", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebase(workspaceKey: ws, ontoBranch: "origin/main")
            },
            Command(id: "git.rebaseContinue", title: "Git: Continue Rebase", subtitle: "Continue after resolving conflicts", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebaseContinue(workspaceKey: ws)
            },
            Command(id: "git.rebaseAbort", title: "Git: Abort Rebase", subtitle: "Abort and return to original state", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebaseAbort(workspaceKey: ws)
            },
            Command(id: "git.aiResolve", title: "Git: Resolve Conflicts with AI", subtitle: "Open terminal with opencode", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.currentGlobalWorkspaceKey else { return }
                app.spawnTerminalWithCommand(workspaceKey: ws, command: "opencode")
            },
            // UX-4: Git rebase onto default (integration worktree) commands
            Command(id: "git.rebaseOntoDefault", title: "Git: Safe Rebase onto Default", subtitle: "Rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebaseOntoDefault(workspaceKey: ws)
            },
            Command(id: "git.rebaseOntoDefaultContinue", title: "Git: Continue Safe Rebase", subtitle: "Continue rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebaseOntoDefaultContinue(workspaceKey: ws)
            },
            Command(id: "git.rebaseOntoDefaultAbort", title: "Git: Abort Safe Rebase", subtitle: "Abort rebase in integration worktree", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitRebaseOntoDefaultAbort(workspaceKey: ws)
            },
            // UX-5: Git reset integration worktree command
            Command(id: "git.resetIntegrationWorktree", title: "Git: Reset Integration Worktree", subtitle: "Reset integration worktree to clean state", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitResetIntegrationWorktree(workspaceKey: ws)
            },
            // UX-6: Git check branch up to date command
            Command(id: "git.checkBranchUpToDate", title: "Git: Check Branch Up To Date", subtitle: "Check if branch is behind default", scope: .workspace, keyHint: nil) { app in
                guard let ws = app.selectedWorkspaceKey else { return }
                app.gitCache.gitCheckBranchUpToDate(workspaceKey: ws)
            }
        ]
    }
}
