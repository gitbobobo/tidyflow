import Foundation

// MARK: - AI Agent 模型

/// AI Agent 枚举（用于 AI 合并到默认分支功能）
enum AIAgent: String, CaseIterable, Identifiable {
    case claude
    case codex
    case gemini
    case opencode
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex CLI"
        case .gemini: return "Gemini CLI"
        case .opencode: return "OpenCode"
        case .cursor: return "Cursor Agent"
        }
    }

    var brandIcon: BrandIcon {
        switch self {
        case .claude: return .claude
        case .codex: return .codex
        case .gemini: return .gemini
        case .opencode: return .opencode
        case .cursor: return .cursor
        }
    }

    /// 构建非交互模式命令参数
    /// - Parameter prompt: AI Agent 执行的提示词
    /// 同一代理在不同业务入口（AI 合并 / AI 提交）必须使用同一命令模板，差异只通过 prompt 表达。
    func buildCommand(prompt: String) -> [String] {
        switch self {
        case .claude:
            return ["claude", "--dangerously-skip-permissions", "-p", prompt, "--output-format", "json"]
        case .codex:
            // worktree 场景下需要写入 .git/worktrees/* 元数据（如 index.lock），固定使用 bypass 参数避免被沙箱拦截。
            return ["codex", "--dangerously-bypass-approvals-and-sandbox", "exec", prompt]
        case .gemini:
            return ["gemini", "--approval-mode", "yolo", "--no-sandbox", "-p", prompt, "-o", "json"]
        case .opencode:
            return ["opencode", "run", prompt, "--format", "json"]
        case .cursor:
            // Cursor Agent 在提交场景需要关闭沙箱并强制放行命令，否则可能被外层审批拦截。
            return ["cursor-agent", "-p", "--sandbox", "disabled", "-f", prompt, "--output-format", "json"]
        }
    }

    /// 从代理原始输出中提取 AI 回复文本（第一层解析）
    func extractResponse(from output: String) -> String? {
        switch self {
        case .claude, .cursor:
            // 解析外层 JSON → 取 result 字段 → 去除 markdown 代码块
            guard let result = extractEnvelopeStringField(named: "result", from: output) else {
                return nil
            }
            return AIAgentOutputParser.stripMarkdownCodeBlock(result)

        case .codex:
            // JSONL 多行，找最后一个 type=="item.completed" 的 item.text
            var lastText: String?
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      json["type"] as? String == "item.completed",
                      let item = json["item"] as? [String: Any],
                      let text = item["text"] as? String else { continue }
                lastText = text
            }
            return lastText

        case .gemini:
            // 解析外层 JSON → 取 response 字段
            guard let response = extractEnvelopeStringField(named: "response", from: output) else {
                return nil
            }
            return response

        case .opencode:
            // JSONL 多行，取最后一个 type=="text" 事件内容。
            var lastText: String?
            for line in output.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty,
                      let lineData = trimmed.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let text = extractOpenCodeText(from: json) else { continue }
                lastText = text
            }
            return lastText
        }
    }

    /// 从 OpenCode 事件对象中提取 text 内容（兼容不同事件形态）
    private func extractOpenCodeText(from json: [String: Any]) -> String? {
        guard json["type"] as? String == "text" else { return nil }
        if let part = json["part"] as? [String: Any],
           let text = part["text"] as? String {
            return text
        }
        return json["text"] as? String
    }

    /// 从混合输出中提取外层 JSON 的字符串字段（兼容 stdout + stderr 拼接）
    private func extractEnvelopeStringField(named key: String, from output: String) -> String? {
        let normalized = AIAgentOutputParser.sanitizeForJSONParsing(output)
        if let value = decodeStringField(named: key, from: normalized) {
            return value
        }
        for candidate in AIAgentOutputParser.extractBalancedJSONObjects(from: normalized) {
            if let value = decodeStringField(named: key, from: candidate) {
                return value
            }
        }
        return nil
    }

    /// 解析 JSON 对象并读取指定字符串字段
    private func decodeStringField(named key: String, from jsonString: String) -> String? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = json[key] as? String else {
            return nil
        }
        return value
    }
}

/// 构建包含常见 CLI 安装路径的 PATH 环境变量
/// macOS App 默认 PATH 不含 Homebrew、~/.local/bin 等用户路径，需手动补充
private func buildExtendedPATH() -> [String: String] {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let extraPaths = [
        "\(home)/.local/bin",
        "\(home)/.cargo/bin",
        "\(home)/.opencode/bin",
        "\(home)/.bun/bin",
        "/opt/homebrew/bin",
        "/opt/homebrew/sbin",
        "/usr/local/bin",
        "/usr/local/sbin",
    ]
    let systemPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let fullPath = (extraPaths + systemPath.split(separator: ":").map(String.init))
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        .joined(separator: ":")
    var env = ProcessInfo.processInfo.environment
    env["PATH"] = fullPath
    return env
}

/// 通用 AI 代理输出解析器（两层架构）
/// 第一层：从各代理特定的包装格式中提取 AI 回复文本
/// 第二层：从 AI 回复文本中解析业务 JSON
struct AIAgentOutputParser {
    /// 从 AI 代理原始输出中解析业务结果
    static func parse(from output: String, agent: AIAgent) -> (success: Bool, message: String, conflicts: [String])? {
        // 第一层：提取 AI 回复文本
        if let response = agent.extractResponse(from: output),
           let result = parseBusinessJSON(from: response) {
            return result
        }
        // 回退：直接对原始输出尝试第二层解析（兼容直接输出 JSON 的情况）
        return parseBusinessJSON(from: output)
    }

    /// 从文本中解析业务 JSON（第二层，通用）
    static func parseBusinessJSON(from text: String) -> (success: Bool, message: String, conflicts: [String])? {
        let normalized = sanitizeForJSONParsing(text)
        let cleaned = stripMarkdownCodeBlock(normalized)

        // 尝试直接 JSON 解析
        if let result = extractFields(from: cleaned) {
            return result
        }

        // 回退：从混合输出中提取平衡的大括号 JSON 对象
        for candidate in extractBalancedJSONObjects(from: cleaned) {
            if let result = extractFields(from: candidate) {
                return result
            }
        }

        return nil
    }

    /// 去除 markdown 代码块包裹
    static func stripMarkdownCodeBlock(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 匹配 ```json ... ``` 或 ``` ... ```
        if let range = trimmed.range(of: "^```(?:json)?\\s*\\n([\\s\\S]*?)\\n```\\s*$", options: .regularExpression) {
            let inner = trimmed[range]
            // 提取捕获组内容：去掉首行 ``` 和末尾 ```
            let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count >= 2 {
                let content = lines.dropFirst().dropLast().joined(separator: "\n")
                return content.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return trimmed
    }

    /// 清理 ANSI 转义与不可见控制字符，降低 JSON 解析失败概率
    static func sanitizeForJSONParsing(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(of: "\r\n", with: "\n")
        let patterns = [
            "\u{001B}\\[[0-9;?]*[ -/]*[@-~]",                 // CSI
            "\u{001B}\\][^\\u{0007}\\u{001B}]*(?:\\u{0007}|\\u{001B}\\\\)", // OSC
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(cleaned.startIndex..., in: cleaned)
                cleaned = regex.stringByReplacingMatches(
                    in: cleaned,
                    options: [],
                    range: range,
                    withTemplate: ""
                )
            }
        }
        let filteredScalars = cleaned.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x09, 0x0A, 0x0D:
                return true
            default:
                return scalar.value >= 0x20
            }
        }
        return String(String.UnicodeScalarView(filteredScalars))
    }

    /// 提取文本中所有平衡的大括号 JSON 对象（按出现顺序）
    static func extractBalancedJSONObjects(from text: String) -> [String] {
        var objects: [String] = []
        var stackDepth = 0
        var startIndex: String.Index?
        var inString = false
        var escaping = false

        var index = text.startIndex
        while index < text.endIndex {
            let ch = text[index]

            if escaping {
                escaping = false
                index = text.index(after: index)
                continue
            }

            if ch == "\\" && inString {
                escaping = true
                index = text.index(after: index)
                continue
            }

            if ch == "\"" {
                inString.toggle()
                index = text.index(after: index)
                continue
            }

            if !inString {
                if ch == "{" {
                    if stackDepth == 0 {
                        startIndex = index
                    }
                    stackDepth += 1
                } else if ch == "}" && stackDepth > 0 {
                    stackDepth -= 1
                    if stackDepth == 0, let start = startIndex {
                        let end = text.index(after: index)
                        objects.append(String(text[start..<end]))
                        startIndex = nil
                    }
                }
            }

            index = text.index(after: index)
        }

        return objects
    }

    /// 从 JSON 字符串中提取业务字段
    private static func extractFields(from jsonString: String) -> (success: Bool, message: String, conflicts: [String])? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json.keys.contains("success") else {
            return nil
        }
        let success = json["success"] as? Bool ?? false
        let message = json["message"] as? String ?? ""
        let conflicts = json["conflicts"] as? [String] ?? []
        return (success, message, conflicts)
    }
}

/// AI 合并结果
struct AIMergeResult: Identifiable {
    let id = UUID()
    let resultStatus: TaskResultStatus
    let message: String
    let conflicts: [String]
    let rawOutput: String

    /// 从 AI 输出中解析结果（支持不同代理的输出格式）
    static func parse(from output: String, agent: AIAgent) -> AIMergeResult {
        // 使用通用解析器的两层架构
        if let result = AIAgentOutputParser.parse(from: output, agent: agent) {
            return AIMergeResult(resultStatus: result.success ? .success : .failed, message: result.message, conflicts: result.conflicts, rawOutput: output)
        }

        // 无法解析 JSON 时，标记为未知，提示用户自行检查
        return AIMergeResult(
            resultStatus: .unknown,
            message: "sidebar.aiMerge.parseWarning".localized,
            conflicts: [],
            rawOutput: output
        )
    }
}

/// AI 提交条目
struct AICommitEntry: Identifiable {
    let id = UUID()
    let sha: String
    let message: String
    let files: [String]
}

/// AI 智能提交结果
struct AICommitResult: Identifiable {
    let id = UUID()
    let resultStatus: TaskResultStatus
    let message: String
    let commits: [AICommitEntry]
    let rawOutput: String

    /// 从 AI 输出中解析提交结果
    static func parse(from output: String, agent: AIAgent) -> AICommitResult {
        // 第一层：提取 AI 回复文本
        if let response = agent.extractResponse(from: output),
           let result = parseCommitJSON(from: response) {
            return AICommitResult(resultStatus: result.success ? .success : .failed, message: result.message, commits: result.commits, rawOutput: output)
        }
        // 回退：直接对原始输出尝试解析
        if let result = parseCommitJSON(from: output) {
            return AICommitResult(resultStatus: result.success ? .success : .failed, message: result.message, commits: result.commits, rawOutput: output)
        }
        // 无法解析 JSON 时，标记为未知，提示用户自行检查
        return AICommitResult(
            resultStatus: .unknown,
            message: "git.aiCommit.parseWarning".localized,
            commits: [],
            rawOutput: output
        )
    }

    /// 从文本中解析提交 JSON
    private static func parseCommitJSON(from text: String) -> (success: Bool, message: String, commits: [AICommitEntry])? {
        let normalized = AIAgentOutputParser.sanitizeForJSONParsing(text)
        let cleaned = AIAgentOutputParser.stripMarkdownCodeBlock(normalized)

        if let result = extractCommitFields(from: cleaned) { return result }

        // 从混合输出中提取平衡的大括号 JSON 对象
        for candidate in AIAgentOutputParser.extractBalancedJSONObjects(from: cleaned) {
            if let result = extractCommitFields(from: candidate) {
                return result
            }
        }
        return nil
    }

    /// 从 JSON 字符串中提取提交字段
    private static func extractCommitFields(from jsonString: String) -> (success: Bool, message: String, commits: [AICommitEntry])? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json.keys.contains("success") else {
            return nil
        }
        let success = json["success"] as? Bool ?? false
        let message = json["message"] as? String ?? ""
        var commits: [AICommitEntry] = []
        if let rawCommits = json["commits"] as? [[String: Any]] {
            for c in rawCommits {
                let sha = c["sha"] as? String ?? ""
                let msg = c["message"] as? String ?? ""
                let files = c["files"] as? [String] ?? []
                commits.append(AICommitEntry(sha: sha, message: msg, files: files))
            }
        }
        return (success, message, commits)
    }
}

/// AI Agent Prompt 构建器
struct AIAgentPromptBuilder {
    /// 构建合并到默认分支的 prompt
    static func buildMergePrompt(
        featureBranch: String,
        defaultBranch: String,
        projectName: String
    ) -> String {
        return """
        你是一个 Git 操作助手。请在当前目录（默认分支工作区）执行以下合并操作。这是纯本地操作，禁止任何网络请求。

        目标：将功能分支 "\(featureBranch)" 合并到默认分支 "\(defaultBranch)"

        步骤：
        1. 确认当前在默认分支 "\(defaultBranch)" 上，如果不是则执行 git checkout \(defaultBranch)
        2. 执行 git merge \(featureBranch) 合并功能分支
        3. 如果出现冲突：
           a. 逐个打开冲突文件，阅读并理解双方改动的意图
           b. 综合两边的修改进行智能合并——保留双方有意义的改动，而非简单选择某一方
           c. 移除所有冲突标记（<<<<<<<、=======、>>>>>>>）
           d. 确保合并后的代码逻辑正确、可编译
           e. 对每个冲突文件执行 git add 标记为已解决
           f. 所有冲突解决后执行 git commit 完成合并（使用默认合并提交信息）
        4. 合并完成后确认工作区干净（git status 无未提交变更）

        严格禁止：
        - 禁止执行 git pull、git fetch、git push 等任何网络操作
        - 禁止执行 git merge --abort 放弃合并（除非冲突完全无法理解）
        - 遇到冲突时不要放弃，必须尝试解决

        请以严格 JSON 格式输出结果：
        {
          "success": true/false,
          "message": "操作结果描述",
          "conflicts": ["已解决的冲突文件路径列表，无冲突则为空数组"],
          "commands_executed": ["执行的 git 命令列表"],
          "merge_commit_sha": "合并提交的 SHA 或 null"
        }

        只输出 JSON，不要输出其他内容。
        """
    }

    /// 构建 AI 智能提交的 prompt
    static func buildCommitPrompt(
        stagedFiles: [String],
        allChangedFiles: [String],
        branchName: String
    ) -> String {
        let stagedList = stagedFiles.isEmpty ? "（无暂存文件）" : stagedFiles.joined(separator: "\n  - ")
        let changedList = allChangedFiles.isEmpty ? "（无变更文件）" : allChangedFiles.joined(separator: "\n  - ")
        return """
        你是一个 Git 提交助手。请在当前目录分析变更并执行智能提交。这是纯本地操作，禁止任何网络请求。

        当前分支：\(branchName)
        暂存文件：
          - \(stagedList)
        所有变更文件：
          - \(changedList)

        请按以下步骤执行：

        1. **风格检测**：执行 `git log --oneline -30` 分析现有提交风格（conventional commits / plain / sentence case）和语言（中文/英文/混合），后续提交消息必须匹配该风格和语言。

        2. **变更分析**：执行 `git diff --staged`（如有暂存文件）和 `git diff`（如有未暂存变更）理解每个文件的修改意图。

        3. **原子提交规划**：将变更按逻辑分组为原子提交：
           - 按目录/模块/关注点分组
           - 测试文件与对应实现文件配对
           - 每个提交应有单一明确的目的
           - 如果所有变更属于同一逻辑改动，合为一个提交即可

        4. **执行提交**：按依赖顺序逐个执行：
           - 对每组文件执行 `git add <files>`
           - 执行 `git commit -m "<message>"`（消息匹配检测到的风格和语言）

        5. **验证**：执行 `git status` 和 `git log --oneline -5` 确认结果。

        严格禁止：
        - 禁止执行 git pull、git fetch、git push 等任何网络操作
        - 禁止修改任何文件内容（只能 git add 和 git commit）
        - 禁止执行 git commit --amend、git rebase、git reset 等危险操作
        - 禁止创建或切换分支

        请以严格 JSON 格式输出结果：
        {
          "success": true/false,
          "message": "操作结果描述",
          "commits": [
            {
              "sha": "提交的短 SHA",
              "message": "提交消息",
              "files": ["提交包含的文件路径列表"]
            }
          ]
        }

        只输出 JSON，不要输出其他内容。
        """
    }
}

/// AI Agent 执行器
class AIAgentRunner {
    /// 原始进程执行结果
    struct RawResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
        var fullOutput: String {
            stdout + (stderr.isEmpty ? "" : "\n--- stderr ---\n\(stderr)")
        }
    }

    /// 执行 AI Agent 命令，返回原始输出
    static func runRaw(
        agent: AIAgent,
        prompt: String,
        workingDirectory: String,
        projectPath: String? = nil
    ) async -> (raw: RawResult?, error: String?) {
        let args = agent.buildCommand(prompt: prompt)
        NSLog("[AIAgentRunner] agent=%@, workingDir=%@, cmd=%@",
              agent.rawValue, workingDirectory, args.joined(separator: " "))
        guard !args.isEmpty else {
            return (nil, "sidebar.aiMerge.invalidAgent".localized)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)
        process.environment = buildExtendedPATH()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return (nil, String(format: "sidebar.aiMerge.launchFailed".localized, error.localizedDescription))
        }

        // 10 分钟超时
        let timer = DispatchSource.makeTimerSource()
        timer.schedule(deadline: .now() + 600)
        timer.setEventHandler {
            if process.isRunning { process.terminate() }
        }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (RawResult(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus), nil)
    }

    /// 执行 AI Agent 合并命令
    static func run(
        agent: AIAgent,
        prompt: String,
        workingDirectory: String,
        projectPath: String? = nil
    ) async -> AIMergeResult {
        let result = await runRaw(
            agent: agent,
            prompt: prompt,
            workingDirectory: workingDirectory,
            projectPath: projectPath
        )
        if let error = result.error {
            return AIMergeResult(resultStatus: .failed, message: error, conflicts: [], rawOutput: "")
        }
        guard let raw = result.raw else {
            return AIMergeResult(resultStatus: .failed, message: "sidebar.aiMerge.invalidAgent".localized, conflicts: [], rawOutput: "")
        }
        if raw.exitCode != 0 && raw.stdout.isEmpty {
            return AIMergeResult(
                resultStatus: .failed,
                message: String(format: "sidebar.aiMerge.exitCode".localized, raw.exitCode),
                conflicts: [],
                rawOutput: raw.fullOutput
            )
        }
        return AIMergeResult.parse(from: raw.fullOutput, agent: agent)
    }

    /// 执行 AI Agent 智能提交命令
    static func runCommit(
        agent: AIAgent,
        prompt: String,
        workingDirectory: String,
        projectPath: String? = nil
    ) async -> AICommitResult {
        let result = await runRaw(
            agent: agent,
            prompt: prompt,
            workingDirectory: workingDirectory,
            projectPath: projectPath
        )
        if let error = result.error {
            return AICommitResult(resultStatus: .failed, message: error, commits: [], rawOutput: "")
        }
        guard let raw = result.raw else {
            return AICommitResult(resultStatus: .failed, message: "sidebar.aiMerge.invalidAgent".localized, commits: [], rawOutput: "")
        }
        if raw.exitCode != 0 && raw.stdout.isEmpty {
            return AICommitResult(
                resultStatus: .failed,
                message: String(format: "sidebar.aiMerge.exitCode".localized, raw.exitCode),
                commits: [],
                rawOutput: raw.fullOutput
            )
        }
        return AICommitResult.parse(from: raw.fullOutput, agent: agent)
    }
}
