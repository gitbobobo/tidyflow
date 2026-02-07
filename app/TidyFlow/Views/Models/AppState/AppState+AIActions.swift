import Foundation

extension AppState {
    // MARK: - AI Agent 合并

    /// 执行 AI 合并到默认分支
    func executeAIMerge(
        projectName: String,
        workspaceName: String
    ) async -> AIMergeResult {
        // 1. 获取 AI Agent
        guard let agentName = clientSettings.selectedAIAgent,
              let agent = AIAgent(rawValue: agentName) else {
            return AIMergeResult(
                success: false,
                message: "settings.aiAgent.notConfigured".localized,
                conflicts: [],
                rawOutput: ""
            )
        }

        // 2. 获取项目路径（默认工作空间路径）
        guard let project = projects.first(where: { $0.name == projectName }),
              let projectPath = project.path else {
            return AIMergeResult(
                success: false,
                message: "sidebar.aiMerge.noProjectPath".localized,
                conflicts: [],
                rawOutput: ""
            )
        }

        // 3. 获取功能分支名和默认分支名
        let wsKey = workspaceName
        let featureBranch = gitCache.gitBranchCache[wsKey]?.current ?? workspaceName
        // 默认分支从默认工作空间的分支信息获取，兜底为 "main"
        let defaultBranch = gitCache.gitBranchCache["default"]?.current ?? "main"

        // 4. 构建 prompt
        let prompt = AIAgentPromptBuilder.buildMergePrompt(
            featureBranch: featureBranch,
            defaultBranch: defaultBranch,
            projectName: projectName
        )

        // 5. 执行 AI Agent（工作目录为项目根目录）
        return await AIAgentRunner.run(
            agent: agent,
            prompt: prompt,
            workingDirectory: projectPath,
            projectPath: projectPath
        )
    }

    // MARK: - AI Agent 智能提交

    /// 执行 AI 智能提交
    func executeAICommit(workspaceKey: String, workspacePath: String, projectPath: String? = nil) async -> AICommitResult {
        // 1. 获取 AI Agent
        guard let agentName = clientSettings.selectedAIAgent,
              let agent = AIAgent(rawValue: agentName) else {
            return AICommitResult(
                success: false,
                message: "settings.aiAgent.notConfigured".localized,
                commits: [],
                rawOutput: ""
            )
        }

        // 2. 获取暂存/变更文件列表（仅用于 prompt 提示，不做前置校验）
        let statusCache = gitCache.gitStatusCache[workspaceKey] ?? GitStatusCache.empty()
        let stagedFiles = statusCache.items.filter { $0.staged == true }.map { $0.path }
        let allChangedFiles = statusCache.items.map { $0.path }

        // 3. 获取当前分支名
        let branchName = gitCache.gitBranchCache[workspaceKey]?.current ?? "unknown"

        // 4. 构建 prompt 并执行
        let prompt = AIAgentPromptBuilder.buildCommitPrompt(
            stagedFiles: stagedFiles,
            allChangedFiles: allChangedFiles,
            branchName: branchName
        )

        return await AIAgentRunner.runCommit(
            agent: agent,
            prompt: prompt,
            workingDirectory: workspacePath,
            projectPath: projectPath
        )
    }
}
