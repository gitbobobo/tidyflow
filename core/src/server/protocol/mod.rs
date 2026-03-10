use serde::{Deserialize, Serialize};

// 按领域拆分的协议类型子模块（组织性拆分，保持类型引用路径不变）
pub mod action_table;
pub mod ai;
pub mod domain_table;
pub mod file;
pub mod git;
pub mod health;
pub mod project;
pub mod settings;
pub mod terminal;

#[cfg(test)]
mod action_table_test;
#[cfg(test)]
mod ai_session_update_test;

/// Protocol version: 8 (MessagePack binary encoding + domain/action envelope)
pub const PROTOCOL_VERSION: u32 = 8;

// ============================================================================
// 多工作区边界字段约束（v7 协议层权威声明）
//
// 所有 ServerMessage 变体在适用时**必须**携带以下字段，用于客户端按
// (project, workspace) 二元组将事件/结果路由到正确的缓存桶：
//
//   project    : 所属项目名称（全部 domain 的事件和 HTTP 响应）
//   workspace  : 所属工作区名称（同上）
//   session_id : AI 会话 ID（AI 相关消息中条件必须）
//   cycle_id   : Evolution 循环 ID（Evolution 相关消息中条件必须）
//
// 约束规则：
// - 客户端不允许仅凭 workspace 名称路由（不同项目可能有同名工作区）。
// - 不允许以 "default" 或当前激活工作区作为隐含单例上下文。
// - HTTP snapshot 与 WS 流式事件共用兼容的 (project, workspace, session_id, cycle_id) 语义，
//   不允许两套键规则并存。
// - 来自其他工作区的消息不允许覆盖当前激活工作区的 UI 状态。
// ============================================================================

// ============================================================================
// v6 包络结构（在 v7 继续沿用）
// ============================================================================

/// 客户端请求包络（结构沿用 v6）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientEnvelopeV6 {
    pub request_id: String,
    pub domain: String,
    pub action: String,
    #[serde(default)]
    pub payload: serde_json::Value,
    /// 客户端发送时间（Unix ms）
    #[serde(default)]
    pub client_ts: u64,
}

/// 服务端响应包络（结构沿用 v6）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerEnvelopeV6 {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
    /// 服务端单调序号（全局）
    pub seq: u64,
    pub domain: String,
    pub action: String,
    pub kind: String, // "result" | "event" | "error"
    #[serde(default)]
    pub payload: serde_json::Value,
    /// 服务端发送时间（Unix ms）
    pub server_ts: u64,
}

// ============================================================================
// v0 Messages (Terminal Data Plane) - Backward Compatible
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ClientMessage {
    // v0: Terminal data plane (term_id optional for backward compat)
    Input {
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Resize {
        cols: u16,
        rows: u16,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Ping,

    // v1: Control plane - Workspace management
    ListProjects,
    ListWorkspaces {
        project: String,
    },
    SelectWorkspace {
        project: String,
        workspace: String,
    },
    SpawnTerminal {
        cwd: String,
    },

    // v1: Session management
    KillTerminal,

    // v1.1: Multi-terminal extension
    TermCreate {
        project: String,
        workspace: String,
        /// 可选初始尺寸，避免创建后再 resize 导致提示符重绘
        #[serde(default)]
        cols: Option<u16>,
        #[serde(default)]
        rows: Option<u16>,
        /// 客户端自定义展示名称（如命令名），用于重连恢复
        #[serde(default)]
        name: Option<String>,
        /// 客户端自定义图标标识，用于重连恢复
        #[serde(default)]
        icon: Option<String>,
    },
    TermList,
    TermClose {
        term_id: String,
    },
    TermFocus {
        term_id: String,
    },

    // v1.3: File operations
    FileList {
        project: String,
        workspace: String,
        #[serde(default)]
        path: String,
    },
    FileRead {
        project: String,
        workspace: String,
        path: String,
    },
    FileWrite {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
    },

    // v1.4: File index for Quick Open
    FileIndex {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        query: Option<String>,
    },

    // v1.5: Git tools
    GitStatus {
        project: String,
        workspace: String,
    },
    GitDiff {
        project: String,
        workspace: String,
        path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base: Option<String>,
        #[serde(default = "default_diff_mode")]
        mode: String, // "working" or "staged"
    },

    // v1.6: Git stage/unstage operations
    GitStage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = stage all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
    },
    GitUnstage {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = unstage all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
    },

    // v1.7: Git discard (working tree changes)
    GitDiscard {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>, // None = discard all
        #[serde(default = "default_git_scope")]
        scope: String, // "file" or "all"
        #[serde(default)]
        include_untracked: bool, // scope="all" 时是否同时删除未跟踪文件
    },

    // v1.8: Git branch operations
    GitBranches {
        project: String,
        workspace: String,
    },
    GitSwitchBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    // v1.9: Git create branch
    GitCreateBranch {
        project: String,
        workspace: String,
        branch: String,
    },
    // v1.10: Git commit
    GitCommit {
        project: String,
        workspace: String,
        message: String,
    },

    // v1.11: Git rebase/fetch operations (UX-3a)
    GitFetch {
        project: String,
        workspace: String,
    },
    GitRebase {
        project: String,
        workspace: String,
        onto_branch: String,
    },
    GitRebaseContinue {
        project: String,
        workspace: String,
    },
    GitRebaseAbort {
        project: String,
        workspace: String,
    },
    GitOpStatus {
        project: String,
        workspace: String,
    },

    // v1.12: Git merge to default via integration worktree (UX-3b)
    GitEnsureIntegrationWorktree {
        project: String,
    },
    GitMergeToDefault {
        project: String,
        workspace: String,
        default_branch: String,
    },
    GitMergeContinue {
        project: String,
    },
    GitMergeAbort {
        project: String,
    },
    GitIntegrationStatus {
        project: String,
    },

    // v1.13: Git rebase onto default via integration worktree (UX-4)
    GitRebaseOntoDefault {
        project: String,
        workspace: String,
        default_branch: String,
    },
    GitRebaseOntoDefaultContinue {
        project: String,
    },
    GitRebaseOntoDefaultAbort {
        project: String,
    },

    // v1.14: Git reset integration worktree (UX-5)
    GitResetIntegrationWorktree {
        project: String,
    },

    // v1.15: Git check branch up to date (UX-6)
    GitCheckBranchUpToDate {
        project: String,
        workspace: String,
    },

    // v1.16: Project/Workspace import
    ImportProject {
        name: String,
        path: String,
    },
    CreateWorkspace {
        project: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        from_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        template_id: Option<String>,
    },

    // v1.17: Remove project
    RemoveProject {
        name: String,
    },

    // v1.18: Remove workspace
    RemoveWorkspace {
        project: String,
        workspace: String,
    },

    // v1.19: Git log (commit history)
    GitLog {
        project: String,
        workspace: String,
        #[serde(default = "default_git_log_limit")]
        limit: usize,
    },

    // v1.20: Git show (single commit details)
    GitShow {
        project: String,
        workspace: String,
        sha: String,
    },

    // v1.40: 冲突向导动作
    /// 读取单个冲突文件的四路对比内容
    GitConflictDetail {
        project: String,
        workspace: String,
        path: String,
        /// 上下文来源：workspace | integration
        context: String,
    },
    /// 接受我方版本并暂存
    GitConflictAcceptOurs {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 接受对方版本并暂存
    GitConflictAcceptTheirs {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 合并双方版本（ours 在前，theirs 在后）并暂存
    GitConflictAcceptBoth {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },
    /// 手工编辑后标记已解决（git add）
    GitConflictMarkResolved {
        project: String,
        workspace: String,
        path: String,
        context: String,
    },

    // v1.21: Client settings
    GetClientSettings,
    SaveClientSettings {
        custom_commands: Vec<CustomCommandInfo>,
        #[serde(default)]
        workspace_shortcuts: std::collections::HashMap<String, String>,
        /// 用于合并操作的 AI Agent
        #[serde(default)]
        merge_ai_agent: Option<String>,
        /// 固定端口，0 表示动态分配
        #[serde(default)]
        fixed_port: Option<u16>,
        /// 是否开启远程访问（开启后允许局域网连接）
        #[serde(default)]
        remote_access_enabled: Option<bool>,
        /// Evolution 全局默认配置；为 None 时保持服务端现值不变。
        #[serde(default)]
        evolution_default_profiles: Option<Vec<EvolutionStageProfileInfo>>,
        /// 工作空间待办（key: "project:workspace"）；为 None 时保持服务端现值不变。
        #[serde(default)]
        workspace_todos: Option<std::collections::HashMap<String, Vec<WorkspaceTodoInfo>>>,
        /// 快捷键绑定配置；为 None 时保持服务端现值不变。
        #[serde(default)]
        keybindings: Option<Vec<KeybindingConfigInfo>>,
    },

    // v1.22: File watcher
    WatchSubscribe {
        project: String,
        workspace: String,
    },
    WatchUnsubscribe,

    // v1.23: File rename/delete
    FileRename {
        project: String,
        workspace: String,
        old_path: String,
        new_name: String,
    },
    FileDelete {
        project: String,
        workspace: String,
        path: String,
    },

    // v1.24: File copy (使用绝对路径支持跨项目/外部文件复制)
    FileCopy {
        dest_project: String,
        dest_workspace: String,
        source_absolute_path: String, // 源文件绝对路径
        dest_dir: String,             // 目标目录（相对路径）
    },

    // v1.25: File move (拖拽移动)
    FileMove {
        project: String,
        workspace: String,
        old_path: String, // 源文件相对路径
        new_dir: String,  // 目标目录相对路径
    },

    // v1.33: AI Git merge
    #[serde(rename = "git_ai_merge")]
    GitAIMerge {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        ai_agent: Option<String>,
        default_branch: String,
    },

    // v1.27: Terminal persistence — 重连附着
    TermAttach {
        term_id: String,
    },

    // v1.38: Terminal detach — 仅取消当前 WS 连接的输出订阅，不关闭 PTY（移动端页面切换用）
    TermDetach {
        term_id: String,
    },

    // v1.28: Terminal output flow control — 背压 ACK
    TermOutputAck {
        term_id: String,
        bytes: u64,
    },

    // v1.29: 项目命令管理
    SaveProjectCommands {
        project: String,
        commands: Vec<ProjectCommandInfo>,
    },
    RunProjectCommand {
        project: String,
        workspace: String,
        command_id: String,
    },
    CancelProjectCommand {
        project: String,
        workspace: String,
        command_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        task_id: Option<String>,
    },

    // v1.40: 工作流模板管理
    ListTemplates,
    SaveTemplate {
        template: TemplateInfo,
    },
    DeleteTemplate {
        template_id: String,
    },
    ExportTemplate {
        template_id: String,
    },
    ImportTemplate {
        template: TemplateInfo,
    },

    // v1.30: 客户端日志上报（v1.30.1: 添加结构化错误码与上下文）
    LogEntry {
        level: String,
        source: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        category: Option<String>,
        msg: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        detail: Option<String>,
        /// 结构化错误码（仅错误级别日志携带，Apple 端与 Core 端共享）
        #[serde(skip_serializing_if = "Option::is_none")]
        error_code: Option<String>,
        /// 错误上下文：用于多项目/多工作区场景下关联错误归属
        #[serde(skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cycle_id: Option<String>,
    },

    // v1.37: 取消 AI 任务
    CancelAiTask {
        project: String,
        workspace: String,
        operation_type: String, // "ai_commit" | "ai_merge"
    },

    // v1.39: iOS 剪贴板图片上传（转 JPG 写入 macOS 系统剪贴板）
    ClipboardImageUpload {
        #[serde(with = "serde_bytes")]
        image_data: Vec<u8>,
    },

    // vNext: AI Chat（单 serve + x-opencode-directory 路由，结构化 message/part 流）
    #[serde(rename = "ai_chat_start")]
    AIChatStart {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
    },
    #[serde(rename = "ai_chat_send")]
    AIChatSend {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        file_refs: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        image_parts: Option<Vec<ai::ImagePart>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        audio_parts: Option<Vec<ai::AudioPart>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<ai::ModelSelection>,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        project_mentions: Option<Vec<String>>,
    },
    #[serde(rename = "ai_chat_command")]
    AIChatCommand {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        command: String,
        arguments: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        file_refs: Option<Vec<String>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        image_parts: Option<Vec<ai::ImagePart>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        audio_parts: Option<Vec<ai::AudioPart>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        model: Option<ai::ModelSelection>,
        #[serde(skip_serializing_if = "Option::is_none")]
        agent: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        config_overrides: Option<std::collections::HashMap<String, serde_json::Value>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        project_mentions: Option<Vec<String>>,
    },
    #[serde(rename = "ai_chat_abort")]
    AIChatAbort {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },
    #[serde(rename = "ai_question_reply")]
    AIQuestionReply {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        request_id: String,
        answers: Vec<Vec<String>>,
    },
    #[serde(rename = "ai_question_reject")]
    AIQuestionReject {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        request_id: String,
    },
    #[serde(rename = "ai_session_list")]
    AISessionList {
        project_name: String,
        workspace_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        ai_tool: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cursor: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        limit: Option<u32>,
    },
    #[serde(rename = "ai_session_messages")]
    AISessionMessages {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        before_message_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        limit: Option<i64>,
    },
    #[serde(rename = "ai_session_delete")]
    AISessionDelete {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },
    #[serde(rename = "ai_session_status")]
    AISessionStatus {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },
    #[serde(rename = "ai_session_subscribe")]
    AISessionSubscribe {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },
    #[serde(rename = "ai_session_unsubscribe")]
    AISessionUnsubscribe {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },

    // vNext: AI Provider/Agent 列表
    #[serde(rename = "ai_provider_list")]
    AIProviderList {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
    },
    #[serde(rename = "ai_agent_list")]
    AIAgentList {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
    },

    // vNext: AI 斜杠命令列表
    #[serde(rename = "ai_slash_commands")]
    AISlashCommands {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    #[serde(rename = "ai_session_config_options")]
    AISessionConfigOptions {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
    },
    #[serde(rename = "ai_session_set_config_option")]
    AISessionSetConfigOption {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        option_id: String,
        value: serde_json::Value,
    },
    #[serde(rename = "ai_session_rename")]
    AISessionRename {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        new_title: String,
    },
    #[serde(rename = "ai_session_search")]
    AISessionSearch {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        query: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        limit: Option<u32>,
    },
    #[serde(rename = "ai_code_review")]
    AICodeReview {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        diff_text: String,
        #[serde(default)]
        file_paths: Vec<String>,
    },

    // vNext: AI 代码补全
    #[serde(rename = "ai_code_completion")]
    AICodeCompletion {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        request: ai::CodeCompletionRequest,
    },
    #[serde(rename = "ai_code_completion_abort")]
    AICodeCompletionAbort {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        request_id: String,
    },

    // vNext: Evolution 自主进化
    #[serde(rename = "evo_start_workspace")]
    EvoStartWorkspace {
        project: String,
        workspace: String,
        #[serde(default)]
        priority: i32,
        #[serde(default)]
        loop_round_limit: Option<u32>,
        #[serde(default)]
        stage_profiles: Vec<EvolutionStageProfileInfo>,
    },
    #[serde(rename = "evo_stop_workspace")]
    EvoStopWorkspace {
        project: String,
        workspace: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "evo_stop_all")]
    EvoStopAll {
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "evo_resume_workspace")]
    EvoResumeWorkspace {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evo_get_snapshot")]
    EvoGetSnapshot {
        #[serde(skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
    },
    #[serde(rename = "evo_update_agent_profile")]
    EvoUpdateAgentProfile {
        project: String,
        workspace: String,
        stage_profiles: Vec<EvolutionStageProfileInfo>,
    },
    #[serde(rename = "evo_get_agent_profile")]
    EvoGetAgentProfile {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evo_resolve_blockers")]
    EvoResolveBlockers {
        project: String,
        workspace: String,
        #[serde(default)]
        resolutions: Vec<EvolutionBlockerResolutionInput>,
    },
    #[serde(rename = "evo_list_cycle_history")]
    EvoListCycleHistory {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evo_auto_commit")]
    EvoAutoCommit {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evo_adjust_loop_round")]
    EvoAdjustLoopRound {
        project: String,
        workspace: String,
        loop_round_limit: u32,
    },
    #[serde(rename = "evidence_get_snapshot")]
    EvidenceGetSnapshot {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evidence_get_rebuild_prompt")]
    EvidenceGetRebuildPrompt {
        project: String,
        workspace: String,
    },
    #[serde(rename = "evidence_read_item")]
    EvidenceReadItem {
        project: String,
        workspace: String,
        item_id: String,
        #[serde(default)]
        offset: u64,
        #[serde(default)]
        limit: Option<u32>,
    },

    // v1.40: 查询任务历史（iOS 重连恢复）
    ListTasks,

    // v1.41: 系统健康上报（客户端 → Core）
    #[serde(rename = "health_report")]
    HealthReport {
        /// 客户端会话标识（用于多端并行归属）
        client_session_id: String,
        /// 客户端连接质量（`good` | `degraded` | `lost`）
        connectivity: String,
        /// 客户端本地检测的 incident 列表
        #[serde(default)]
        incidents: Vec<health::HealthIncident>,
        /// 上报上下文
        context: health::HealthContext,
        /// 上报时间（Unix ms）
        reported_at: u64,
    },

    // v1.41: 客户端请求执行修复动作
    #[serde(rename = "health_repair")]
    HealthRepair {
        request: health::RepairActionRequest,
    },
}

fn default_diff_mode() -> String {
    "working".to_string()
}

fn default_git_scope() -> String {
    "file".to_string()
}

fn default_git_log_limit() -> usize {
    50
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum ServerMessage {
    // v0: Terminal data plane (term_id optional for backward compat)
    Hello {
        version: u32,
        session_id: String,
        shell: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        capabilities: Option<Vec<String>>,
    },
    #[serde(rename = "output_batch")]
    OutputBatch {
        items: Vec<terminal::TerminalOutputBatchItem>,
    },
    Exit {
        code: i32,
        #[serde(skip_serializing_if = "Option::is_none")]
        term_id: Option<String>,
    },
    Pong,

    // v1: Control plane responses
    Projects {
        items: Vec<ProjectInfo>,
    },
    Workspaces {
        project: String,
        items: Vec<WorkspaceInfo>,
    },
    SelectedWorkspace {
        project: String,
        workspace: String,
        root: String,
        session_id: String,
        shell: String,
    },
    TerminalSpawned {
        session_id: String,
        shell: String,
        cwd: String,
    },
    TerminalKilled {
        session_id: String,
    },

    // v1.2: Multi-workspace extension (enhanced term_created/term_list)
    TermCreated {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
    },
    TermList {
        items: Vec<TerminalInfo>,
    },
    TermClosed {
        term_id: String,
    },

    // v1.3: File operation responses
    FileListResult {
        project: String,
        workspace: String,
        path: String,
        items: Vec<FileEntryInfo>,
    },
    FileReadResult {
        project: String,
        workspace: String,
        path: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
        size: u64,
    },
    FileWriteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        size: u64,
    },

    // v1.4: File index result for Quick Open
    FileIndexResult {
        project: String,
        workspace: String,
        items: Vec<String>,
        truncated: bool,
    },

    // v1.10: File external change conflict detection
    /// 文件外部变更冲突检测通知（由 watcher 触发）
    FileConflictDetected {
        project: String,
        workspace: String,
        path: String,
        /// 本地修改时间（Unix ms）
        local_modified_at: i64,
        /// 外部修改时间（Unix ms）
        external_modified_at: i64,
        /// 本地内容哈希（用于比较）
        local_hash: String,
        /// 外部内容哈希（用于比较）
        external_hash: String,
    },
    /// 文件冲突解决请求（客户端 -> 服务端）
    FileConflictResolve {
        project: String,
        workspace: String,
        path: String,
        /// "reload" | "overwrite" | "diff"
        action: String,
    },
    /// 文件冲突解决结果（服务端 -> 客户端）
    FileConflictResolveResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        action: String,
        /// 如果是 reload 或 diff，返回外部内容
        #[serde(skip_serializing_if = "Option::is_none")]
        content: Option<Vec<u8>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.5: Git tools results
    GitStatusResult {
        project: String,
        workspace: String,
        repo_root: String,
        items: Vec<GitStatusEntry>,
        #[serde(default)]
        has_staged_changes: bool,
        #[serde(default)]
        staged_count: usize,
        #[serde(skip_serializing_if = "Option::is_none")]
        current_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        default_branch: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        compared_branch: Option<String>,
    },
    GitDiffResult {
        project: String,
        workspace: String,
        path: String,
        code: String,
        format: String,
        text: String,
        is_binary: bool,
        truncated: bool,
        mode: String, // Echo back the mode
        #[serde(skip_serializing_if = "Option::is_none")]
        base: Option<String>,
    },

    // v1.6: Git operation result
    GitOpResult {
        project: String,
        workspace: String,
        op: String, // "stage", "unstage", "discard", "switch_branch", or "create_branch"
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
        scope: String, // "file" or "all"
    },

    // v1.8: Git branches result
    GitBranchesResult {
        project: String,
        workspace: String,
        current: String,
        branches: Vec<GitBranchInfo>,
    },

    // v1.10: Git commit result
    GitCommitResult {
        project: String,
        workspace: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        sha: Option<String>,
    },

    // v1.11: Git rebase result (UX-3a)
    GitRebaseResult {
        project: String,
        workspace: String,
        ok: bool,
        state: String, // "completed", "conflict", "aborted", "error"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<ConflictFileEntryInfo>,
    },

    // v1.11: Git operation status result (UX-3a)
    GitOpStatusResult {
        project: String,
        workspace: String,
        state: String, // "normal", "rebasing", "merging"
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        onto: Option<String>,
    },

    // v1.12: Git merge to default result (UX-3b)
    GitMergeToDefaultResult {
        project: String,
        ok: bool,
        state: String, // "idle", "merging", "conflict", "completed", "failed"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },

    // v1.12: Git integration worktree status result (UX-3b)
    GitIntegrationStatusResult {
        project: String,
        state: String, // "idle", "merging", "conflict", "rebasing", "rebase_conflict"
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head: Option<String>,
        default_branch: String,
        path: String,
        is_clean: bool,
        // v1.15: Branch divergence info (UX-6)
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_ahead_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        branch_behind_by: Option<i32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        compared_branch: Option<String>,
    },

    // v1.13: Git rebase onto default result (UX-4)
    GitRebaseOntoDefaultResult {
        project: String,
        ok: bool,
        state: String, // "idle", "rebasing", "rebase_conflict", "completed", "failed"
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(default)]
        conflicts: Vec<String>,
        /// 语义化冲突文件列表（v1.40+）
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        conflict_files: Vec<ConflictFileEntryInfo>,
        #[serde(skip_serializing_if = "Option::is_none")]
        head_sha: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        integration_path: Option<String>,
    },

    // v1.14: Git reset integration worktree result (UX-5)
    GitResetIntegrationWorktreeResult {
        project: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        path: Option<String>,
    },

    // v1: Error handling
    Error {
        code: String,
        message: String,
        /// 可选错误上下文：多项目/多工作区环境下标识错误归属
        #[serde(skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cycle_id: Option<String>,
    },

    // v1.16: Project/Workspace import results
    ProjectImported {
        name: String,
        root: String,
        default_branch: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<WorkspaceInfo>,
    },
    WorkspaceCreated {
        project: String,
        workspace: WorkspaceInfo,
    },

    // v1.17: Remove project result
    ProjectRemoved {
        name: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.18: Remove workspace result
    WorkspaceRemoved {
        project: String,
        workspace: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.19: Git log result
    GitLogResult {
        project: String,
        workspace: String,
        entries: Vec<GitLogEntryInfo>,
    },

    // v1.20: Git show result (single commit details)
    GitShowResult {
        project: String,
        workspace: String,
        sha: String,
        full_sha: String,
        message: String,
        author: String,
        author_email: String,
        date: String,
        files: Vec<GitShowFileInfo>,
    },

    // v1.21: Client settings result
    ClientSettingsResult {
        custom_commands: Vec<CustomCommandInfo>,
        workspace_shortcuts: std::collections::HashMap<String, String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        merge_ai_agent: Option<String>,
        fixed_port: u16,
        remote_access_enabled: bool,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        evolution_default_profiles: Vec<EvolutionStageProfileInfo>,
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        evolution_agent_profiles: std::collections::HashMap<String, Vec<EvolutionStageProfileInfo>>,
        #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
        workspace_todos: std::collections::HashMap<String, Vec<WorkspaceTodoInfo>>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        keybindings: Vec<KeybindingConfigInfo>,
    },
    ClientSettingsSaved {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.22: File watcher notifications
    WatchSubscribed {
        project: String,
        workspace: String,
    },
    WatchUnsubscribed,
    FileChanged {
        project: String,
        workspace: String,
        paths: Vec<String>,
        kind: String,
    },
    GitStatusChanged {
        project: String,
        workspace: String,
    },

    // v1.40: 冲突向导响应
    /// 单文件冲突详情（四路对比内容）
    GitConflictDetailResult {
        project: String,
        workspace: String,
        /// 上下文来源：workspace | integration
        context: String,
        path: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        base_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ours_content: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        theirs_content: Option<String>,
        current_content: String,
        conflict_markers_count: usize,
        is_binary: bool,
    },
    /// 冲突解决动作结果（含最新冲突快照）
    GitConflictActionResult {
        project: String,
        workspace: String,
        context: String,
        path: String,
        /// 已执行的动作：accept_ours | accept_theirs | accept_both | mark_resolved
        action: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
        /// 操作后的冲突快照
        snapshot: ConflictSnapshotInfo,
    },

    // v1.23: File rename/delete results
    FileRenameResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    FileDeleteResult {
        project: String,
        workspace: String,
        path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.24: File copy result
    FileCopyResult {
        project: String,
        workspace: String,
        source_absolute_path: String,
        dest_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.25: File move result
    FileMoveResult {
        project: String,
        workspace: String,
        old_path: String,
        new_path: String,
        success: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.33: AI Git merge result
    #[serde(rename = "git_ai_merge_result")]
    GitAIMergeResult {
        project: String,
        workspace: String,
        success: bool,
        message: String,
        #[serde(default)]
        conflicts: Vec<String>,
    },

    // v1.27: Terminal persistence — 附着响应
    TermAttached {
        term_id: String,
        project: String,
        workspace: String,
        cwd: String,
        shell: String,
        #[serde(with = "serde_bytes")]
        scrollback: Vec<u8>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        name: Option<String>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        icon: Option<String>,
    },

    // v1.32: 远程终端订阅变更通知（推送给本地连接）
    RemoteTermChanged,

    // v1.29: 项目命令结果
    ProjectCommandsSaved {
        project: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ProjectCommandStarted {
        project: String,
        workspace: String,
        command_id: String,
        task_id: String,
    },
    ProjectCommandCompleted {
        project: String,
        workspace: String,
        command_id: String,
        task_id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    ProjectCommandCancelled {
        project: String,
        workspace: String,
        command_id: String,
        task_id: String,
    },
    /// v1.30: 项目命令实时输出（逐行推送）
    ProjectCommandOutput {
        task_id: String,
        line: String,
    },

    // v1.40: 工作流模板管理
    Templates {
        items: Vec<TemplateInfo>,
    },
    TemplateSaved {
        template: TemplateInfo,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    TemplateDeleted {
        template_id: String,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },
    TemplateExported {
        template: TemplateInfo,
    },
    TemplateImported {
        template: TemplateInfo,
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.37: AI 任务已取消
    #[serde(rename = "ai_task_cancelled")]
    AITaskCancelled {
        project: String,
        workspace: String,
        operation_type: String,
    },

    // v1.39: 剪贴板图片写入结果
    ClipboardImageSet {
        ok: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        message: Option<String>,
    },

    // v1.40: 任务历史快照（iOS 重连恢复）
    TasksSnapshot {
        tasks: Vec<TaskSnapshotEntry>,
    },

    #[serde(rename = "ai_chat_pending")]
    AIChatPending {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
    },
    #[serde(rename = "ai_chat_done")]
    AIChatDone {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        selection_hint: Option<ai::SessionSelectionHint>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stop_reason: Option<String>,
        /// v1.42：路由决策元数据（旧客户端忽略）
        #[serde(skip_serializing_if = "Option::is_none")]
        route_decision: Option<ai::RouteDecisionInfo>,
        /// v1.42：预算状态（旧客户端忽略）
        #[serde(skip_serializing_if = "Option::is_none")]
        budget_status: Option<ai::AiBudgetStatus>,
    },
    #[serde(rename = "ai_chat_error")]
    AIChatErrorV2 {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        error: String,
        /// v1.42：路由决策元数据（旧客户端忽略）
        #[serde(skip_serializing_if = "Option::is_none")]
        route_decision: Option<ai::RouteDecisionInfo>,
    },
    #[serde(rename = "ai_question_asked")]
    AIQuestionAsked {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        request: ai::QuestionRequestInfo,
    },
    #[serde(rename = "ai_question_cleared")]
    AIQuestionCleared {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        request_id: String,
    },
    #[serde(rename = "ai_session_started")]
    AISessionStartedV2 {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        title: String,
        updated_at: i64,
        #[serde(default)]
        session_origin: ai::AiSessionOrigin,
        #[serde(skip_serializing_if = "Option::is_none")]
        selection_hint: Option<ai::SessionSelectionHint>,
    },
    #[serde(rename = "ai_session_list")]
    AISessionListV2 {
        project_name: String,
        workspace_name: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        filter_ai_tool: Option<String>,
        sessions: Vec<ai::SessionInfo>,
        has_more: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        next_cursor: Option<String>,
    },
    #[serde(rename = "ai_session_messages")]
    AISessionMessages {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        before_message_id: Option<String>,
        messages: Vec<ai::MessageInfo>,
        has_more: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        next_before_message_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        selection_hint: Option<ai::SessionSelectionHint>,
        #[serde(skip_serializing_if = "Option::is_none")]
        truncated: Option<bool>,
    },
    #[serde(rename = "ai_session_messages_update")]
    AISessionMessagesUpdate {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        from_revision: u64,
        to_revision: u64,
        is_streaming: bool,
        #[serde(skip_serializing_if = "Option::is_none")]
        selection_hint: Option<ai::SessionSelectionHint>,
        #[serde(skip_serializing_if = "Option::is_none")]
        messages: Option<Vec<ai::MessageInfo>>,
        #[serde(skip_serializing_if = "Option::is_none")]
        ops: Option<Vec<ai::AiSessionCacheOpInfo>>,
    },
    #[serde(rename = "ai_session_status_result")]
    AISessionStatusResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        status: ai::AiSessionStatusInfo,
    },
    #[serde(rename = "ai_session_status_update")]
    AISessionStatusUpdate {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        status: ai::AiSessionStatusInfo,
    },
    #[serde(rename = "ai_session_context_snapshot_result")]
    AISessionContextSnapshotResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        snapshot: Option<ai::AiSessionContextSnapshot>,
    },
    #[serde(rename = "ai_cross_context_snapshots_result")]
    AICrossContextSnapshotsResult {
        project_name: String,
        workspace_name: String,
        snapshots: Vec<ai::AiSessionContextSnapshot>,
    },
    #[serde(rename = "ai_context_snapshot_updated")]
    AIContextSnapshotUpdated {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        snapshot: ai::AiSessionContextSnapshot,
    },
    #[serde(rename = "ai_provider_list")]
    AIProviderListResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        providers: Vec<ai::ProviderInfo>,
    },
    #[serde(rename = "ai_agent_list")]
    AIAgentListResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        agents: Vec<ai::AgentInfo>,
    },
    #[serde(rename = "ai_slash_commands")]
    AISlashCommandsResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        commands: Vec<ai::SlashCommandInfo>,
    },
    #[serde(rename = "ai_slash_commands_update")]
    AISlashCommandsUpdate {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        commands: Vec<ai::SlashCommandInfo>,
    },
    #[serde(rename = "ai_session_config_options")]
    AISessionConfigOptions {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        session_id: Option<String>,
        options: Vec<ai::SessionConfigOptionInfo>,
    },
    #[serde(rename = "ai_session_subscribe_ack")]
    AISessionSubscribeAck {
        /// 订阅确认必须携带 project/workspace，客户端按四元组 (project, workspace, ai_tool, session_id) 路由
        project_name: String,
        workspace_name: String,
        session_id: String,
        session_key: String,
    },
    #[serde(rename = "ai_session_rename_result")]
    AISessionRenameResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        title: String,
        updated_at: i64,
    },
    #[serde(rename = "ai_session_search_result")]
    AISessionSearchResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        query: String,
        sessions: Vec<ai::SessionInfo>,
    },
    #[serde(rename = "ai_code_review_result")]
    AICodeReviewResult {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        session_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        review_text: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        error: Option<String>,
    },

    // vNext: AI 代码补全推送
    #[serde(rename = "ai_code_completion_chunk")]
    AICodeCompletionChunk {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        chunk: ai::CodeCompletionChunk,
    },
    #[serde(rename = "ai_code_completion_done")]
    AICodeCompletionDone {
        project_name: String,
        workspace_name: String,
        ai_tool: String,
        result: ai::CodeCompletionResponse,
    },

    // vNext: Evolution 自主进化
    #[serde(rename = "evo_scheduler_updated")]
    EvoSchedulerUpdated {
        activation_state: String,
        max_parallel_workspaces: u32,
        running_count: u32,
        queued_count: u32,
    },
    #[serde(rename = "evo_scheduler_status")]
    EvoSchedulerStatus {
        activation_state: String,
        max_parallel_workspaces: u32,
        running_count: u32,
        queued_count: u32,
    },
    #[serde(rename = "evo_workspace_started")]
    EvoWorkspaceStarted {
        event_id: String,
        event_seq: u64,
        project: String,
        workspace: String,
        cycle_id: String,
        ts: String,
        source: String,
        status: String,
    },
    #[serde(rename = "evo_workspace_stopped")]
    EvoWorkspaceStopped {
        event_id: String,
        event_seq: u64,
        project: String,
        workspace: String,
        cycle_id: String,
        ts: String,
        source: String,
        status: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        reason: Option<String>,
    },
    #[serde(rename = "evo_workspace_resumed")]
    EvoWorkspaceResumed {
        event_id: String,
        event_seq: u64,
        project: String,
        workspace: String,
        cycle_id: String,
        ts: String,
        source: String,
        status: String,
    },
    #[serde(rename = "evo_stage_changed")]
    EvoStageChanged {
        event_id: String,
        event_seq: u64,
        project: String,
        workspace: String,
        cycle_id: String,
        ts: String,
        source: String,
        from_stage: String,
        to_stage: String,
        verify_iteration: u32,
    },
    #[serde(rename = "evo_cycle_updated")]
    EvoCycleUpdated {
        event_id: String,
        event_seq: u64,
        project: String,
        workspace: String,
        cycle_id: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        title: Option<String>,
        ts: String,
        source: String,
        status: String,
        current_stage: String,
        global_loop_round: u32,
        loop_round_limit: u32,
        verify_iteration: u32,
        verify_iteration_limit: u32,
        agents: Vec<EvolutionAgentInfo>,
        #[serde(default)]
        executions: Vec<EvolutionSessionExecutionEntry>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_reason_code: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        terminal_error_message: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        rate_limit_error_message: Option<String>,
    },
    #[serde(rename = "evo_snapshot")]
    EvoSnapshot {
        scheduler: EvolutionSchedulerInfo,
        workspace_items: Vec<EvolutionWorkspaceItem>,
    },
    #[serde(rename = "evo_agent_profile")]
    EvoAgentProfile {
        project: String,
        workspace: String,
        stage_profiles: Vec<EvolutionStageProfileInfo>,
    },
    #[serde(rename = "evo_blocking_required")]
    EvoBlockingRequired {
        project: String,
        workspace: String,
        trigger: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        cycle_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        stage: Option<String>,
        blocker_file_path: String,
        unresolved_items: Vec<EvolutionBlockerItemInfo>,
    },
    #[serde(rename = "evo_blockers_updated")]
    EvoBlockersUpdated {
        project: String,
        workspace: String,
        unresolved_count: u32,
        unresolved_items: Vec<EvolutionBlockerItemInfo>,
    },
    #[serde(rename = "evo_cycle_history")]
    EvoCycleHistory {
        project: String,
        workspace: String,
        cycles: Vec<EvolutionCycleHistoryItem>,
    },
    #[serde(rename = "evo_auto_commit_result")]
    EvoAutoCommitResult {
        project: String,
        workspace: String,
        success: bool,
        message: String,
        commits: Vec<AIGitCommit>,
    },
    #[serde(rename = "evidence_snapshot")]
    EvidenceSnapshot {
        project: String,
        workspace: String,
        evidence_root: String,
        index_file: String,
        index_exists: bool,
        detected_subsystems: Vec<EvidenceSubsystemInfo>,
        detected_device_types: Vec<String>,
        items: Vec<EvidenceItemInfo>,
        issues: Vec<EvidenceIssueInfo>,
        updated_at: String,
    },
    #[serde(rename = "evidence_rebuild_prompt")]
    EvidenceRebuildPrompt {
        project: String,
        workspace: String,
        prompt: String,
        evidence_root: String,
        index_file: String,
        detected_subsystems: Vec<EvidenceSubsystemInfo>,
        detected_device_types: Vec<String>,
        generated_at: String,
    },
    #[serde(rename = "evidence_item_chunk")]
    EvidenceItemChunk {
        project: String,
        workspace: String,
        item_id: String,
        offset: u64,
        next_offset: u64,
        eof: bool,
        total_size_bytes: u64,
        mime_type: String,
        #[serde(with = "serde_bytes")]
        content: Vec<u8>,
    },
    #[serde(rename = "evo_error")]
    EvoError {
        #[serde(skip_serializing_if = "Option::is_none")]
        event_id: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        event_seq: Option<u64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        project: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        workspace: Option<String>,
        #[serde(skip_serializing_if = "Option::is_none")]
        cycle_id: Option<String>,
        ts: String,
        source: String,
        code: String,
        message: String,
        #[serde(skip_serializing_if = "Option::is_none")]
        context: Option<serde_json::Value>,
    },

    // v1.41: Core 推送系统健康快照
    #[serde(rename = "health_snapshot")]
    HealthSnapshot {
        snapshot: health::SystemHealthSnapshot,
    },

    // v1.41: Core 推送修复执行结果
    #[serde(rename = "health_repair_result")]
    HealthRepairResult {
        audit: health::RepairAuditEntry,
    },
}

// ============================================================================
// v1 Data Types
// ============================================================================

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectInfo {
    pub name: String,
    pub root: String,
    pub workspace_count: usize,
    #[serde(default)]
    pub commands: Vec<ProjectCommandInfo>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct WorkspaceSidebarStatusInfo {
    #[serde(default)]
    pub task_icon: Option<String>,
    #[serde(default)]
    pub chat_active: bool,
    #[serde(default)]
    pub evolution_active: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceInfo {
    pub name: String,
    pub root: String,
    pub branch: String,
    pub status: String,
    #[serde(default)]
    pub sidebar_status: WorkspaceSidebarStatusInfo,
}

// ============================================================================
// 工作区缓存可观测性协议类型
// ============================================================================

/// 文件索引缓存指标（协议传输用，由 Core 权威输出）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct FileCacheMetricsInfo {
    pub hit_count: u64,
    pub miss_count: u64,
    pub rebuild_count: u64,
    pub incremental_update_count: u64,
    pub eviction_count: u64,
    pub item_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_eviction_reason: Option<String>,
}

/// Git 状态缓存指标（协议传输用，由 Core 权威输出）
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct GitCacheMetricsInfo {
    pub hit_count: u64,
    pub miss_count: u64,
    pub rebuild_count: u64,
    pub eviction_count: u64,
    pub item_count: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_eviction_reason: Option<String>,
}

/// 工作区级缓存可观测性快照（HTTP system_snapshot 响应字段）
///
/// 按 `(project, workspace)` 隔离，所有字段由 Core 权威计算，客户端只消费。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceCacheMetricsInfo {
    pub project: String,
    pub workspace: String,
    pub file_cache: FileCacheMetricsInfo,
    pub git_cache: GitCacheMetricsInfo,
    /// true 表示该工作区缓存重建次数已超过预算阈值
    pub budget_exceeded: bool,
    /// 最近一次淘汰原因（文件或 Git 缓存）
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_eviction_reason: Option<String>,
}

/// AI Git commit information
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AIGitCommit {
    pub sha: String,
    pub message: String,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TerminalInfo {
    pub term_id: String,
    pub project: String,
    pub workspace: String,
    pub cwd: String,
    pub status: String, // "running" or "exited"
    #[serde(default)]
    pub shell: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub icon: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub remote_subscribers: Vec<RemoteSubscriberDetail>,
}

/// 远程订阅者详情（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteSubscriberDetail {
    pub device_name: String,
    pub conn_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEntryInfo {
    pub name: String,
    pub is_dir: bool,
    pub size: u64,
    /// 是否被 .gitignore 忽略
    #[serde(default)]
    pub is_ignored: bool,
    /// 是否为符号链接
    #[serde(default)]
    pub is_symlink: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitStatusEntry {
    pub path: String,
    /// 序列化为 "status" 以匹配 Swift 端 GitStatusItem 的字段名
    #[serde(rename = "status")]
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(rename = "rename_from")]
    pub orig_path: Option<String>,
    /// 是否有暂存区变更，用于 UI 区分「暂存的更改」与「未暂存的更改」
    pub staged: bool,
    /// 新增行数（None = 二进制文件或新文件）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub additions: Option<i32>,
    /// 删除行数（None = 二进制文件或新文件）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub deletions: Option<i32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitBranchInfo {
    pub name: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitLogEntryInfo {
    pub sha: String,
    pub message: String,
    pub author: String,
    pub date: String,
    #[serde(default)]
    pub refs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitShowFileInfo {
    pub status: String,
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub old_path: Option<String>,
}

/// 冲突文件条目信息（v1.40: 冲突向导协议 DTO）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictFileEntryInfo {
    /// 文件路径（相对工作区根）
    pub path: String,
    /// 冲突类型：content | add_add | delete_modify | modify_delete
    pub conflict_type: String,
    /// 是否已暂存（标记为已解决）
    pub staged: bool,
}

/// 冲突快照信息（v1.40: 冲突向导协议 DTO）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConflictSnapshotInfo {
    /// 上下文来源：workspace | integration
    pub context: String,
    /// 当前冲突文件列表
    pub files: Vec<ConflictFileEntryInfo>,
    /// 是否所有冲突已解决
    pub all_resolved: bool,
}

/// 自定义命令信息（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CustomCommandInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
}

/// 快捷键绑定配置（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct KeybindingConfigInfo {
    pub command_id: String,
    pub key_combination: String,
    pub context: String,
}

/// 工作空间待办项（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WorkspaceTodoInfo {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub note: Option<String>,
    /// pending | in_progress | completed
    pub status: String,
    pub order: i64,
    pub created_at_ms: i64,
    pub updated_at_ms: i64,
}

/// 项目命令信息（用于协议传输）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProjectCommandInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
    #[serde(default)]
    pub blocking: bool,
    #[serde(default)]
    pub interactive: bool,
}

/// 工作流模板命令（协议传输用）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateCommandInfo {
    pub id: String,
    pub name: String,
    pub icon: String,
    pub command: String,
    #[serde(default)]
    pub blocking: bool,
    #[serde(default)]
    pub interactive: bool,
}

/// 工作流模板（协议传输用）
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TemplateInfo {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub tags: Vec<String>,
    pub commands: Vec<TemplateCommandInfo>,
    #[serde(default)]
    pub env_vars: Vec<(String, String)>,
    #[serde(default)]
    pub builtin: bool,
}

/// 任务快照条目（统一运行状态面板 + iOS 重连恢复）
///
/// 所有字段按 `(project, workspace)` 隔离，客户端不得仅凭 workspace 判断归属。
/// `duration_ms` / `error_code` / `error_detail` / `retryable` 由 Core 权威输出，
/// 客户端只消费，不在本地推导。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TaskSnapshotEntry {
    pub task_id: String,
    pub project: String,
    pub workspace: String,
    pub task_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub command_id: Option<String>,
    pub title: String,
    pub status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    pub started_at: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<i64>,
    /// 运行耗时（毫秒），由 Core 在完成时计算（started_at → completed_at）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// 失败诊断码（与 AppError::code() 对齐，仅 status=failed 时填充）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// 失败诊断详情（可为长文本，仅 status=failed 时填充）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_detail: Option<String>,
    /// 是否可安全重试（Core 根据 task_type + 错误类型判定）
    #[serde(default)]
    pub retryable: bool,
}

/// Evolution 阶段代理配置
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionStageProfileInfo {
    pub stage: String,
    pub ai_tool: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mode: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub model: Option<ai::ModelSelection>,
    #[serde(default, skip_serializing_if = "std::collections::HashMap::is_empty")]
    pub config_options: std::collections::HashMap<String, serde_json::Value>,
}

impl EvolutionStageProfileInfo {
    pub fn normalized_stage(&self) -> String {
        self.stage.trim().to_lowercase()
    }

    pub fn is_legacy_bootstrap_stage(&self) -> bool {
        self.normalized_stage() == "bootstrap"
    }
}

/// Evolution 代理运行信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionAgentInfo {
    pub stage: String,
    pub agent: String,
    pub status: String,
    #[serde(default)]
    pub tool_call_count: u32,
    /// 代理开始运行的 RFC3339 时间戳
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    /// 代理运行耗时（毫秒），仅在完成后填充
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
}

/// Evolution 会话级执行信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionSessionExecutionEntry {
    pub stage: String,
    pub agent: String,
    pub ai_tool: String,
    pub session_id: String,
    pub status: String,
    pub started_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completed_at: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    #[serde(default)]
    pub tool_call_count: u32,
}

/// Evolution 调度器信息
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionSchedulerInfo {
    pub activation_state: String,
    pub max_parallel_workspaces: u32,
    pub running_count: u32,
    pub queued_count: u32,
}

/// Evolution 工作空间快照项
///
/// 统一运行状态面板所需字段：`started_at` / `duration_ms` / `error_code` / `retryable`
/// 由 Core 权威输出，客户端只消费，不在本地推导。
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionWorkspaceItem {
    pub project: String,
    pub workspace: String,
    pub cycle_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub status: String,
    pub current_stage: String,
    pub global_loop_round: u32,
    pub loop_round_limit: u32,
    pub verify_iteration: u32,
    pub verify_iteration_limit: u32,
    pub agents: Vec<EvolutionAgentInfo>,
    #[serde(default)]
    pub executions: Vec<EvolutionSessionExecutionEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_reason_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_error_message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub rate_limit_error_message: Option<String>,
    /// 循环开始时间（RFC3339），用于面板计时
    #[serde(skip_serializing_if = "Option::is_none")]
    pub started_at: Option<String>,
    /// 循环运行耗时（毫秒），Core 在终态时计算
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// 失败诊断码（仅终态失败时填充）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// 是否可安全重试（Core 根据终态类型判定：failed_exhausted 可重试，failed_system 不可重试）
    #[serde(default)]
    pub retryable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionBlockerOptionInfo {
    pub option_id: String,
    pub label: String,
    pub description: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionBlockerItemInfo {
    pub blocker_id: String,
    pub status: String,
    pub cycle_id: String,
    pub stage: String,
    pub created_at: String,
    pub source: String,
    pub title: String,
    pub description: String,
    pub question_type: String,
    #[serde(default)]
    pub options: Vec<EvolutionBlockerOptionInfo>,
    #[serde(default)]
    pub allow_custom_input: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionBlockerResolutionInput {
    pub blocker_id: String,
    #[serde(default)]
    pub selected_option_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub answer_text: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionCycleHistoryItem {
    pub cycle_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub status: String,
    pub global_loop_round: u32,
    pub created_at: String,
    pub updated_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_reason_code: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub terminal_error_message: Option<String>,
    #[serde(default)]
    pub executions: Vec<EvolutionSessionExecutionEntry>,
    pub stages: Vec<EvolutionCycleStageHistoryEntry>,
    /// 循环总耗时（毫秒），由 Core 从 created_at → updated_at 计算
    #[serde(skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<u64>,
    /// 失败诊断码（与 terminal_reason_code 对齐，但提供更精确的错误分类）
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error_code: Option<String>,
    /// 是否可安全重试（failed_exhausted 可重试，failed_system 不可重试）
    #[serde(default)]
    pub retryable: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvolutionCycleStageHistoryEntry {
    pub stage: String,
    pub agent: String,
    pub ai_tool: String,
    pub status: String,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceSubsystemInfo {
    pub id: String,
    pub kind: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceIssueInfo {
    pub code: String,
    pub level: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EvidenceItemInfo {
    pub item_id: String,
    pub device_type: String,
    #[serde(rename = "type")]
    pub evidence_type: String,
    pub order: u32,
    pub path: String,
    pub title: String,
    pub description: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub scenario: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub subsystem: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_at: Option<String>,
    pub size_bytes: u64,
    pub exists: bool,
    pub mime_type: String,
}

// ============================================================================
// v1 Capabilities
// ============================================================================

pub fn v1_capabilities() -> Vec<String> {
    vec![
        "workspace_management".to_string(),
        "multi_terminal".to_string(),
        "multi_workspace".to_string(),
        "cwd_spawn".to_string(),
        "file_operations".to_string(),
        "file_index".to_string(),
        "git_tools".to_string(),
        "git_stage_unstage".to_string(),
        "git_discard".to_string(),
        "git_branches".to_string(),
        "git_create_branch".to_string(),
        "git_commit".to_string(),
        "git_rebase".to_string(),
        "git_merge_integration".to_string(),
        "git_branch_divergence".to_string(),
        "git_conflict_wizard".to_string(),
        "project_import".to_string(),
        "file_watch".to_string(),
        "file_rename_delete".to_string(),
        "file_copy".to_string(),
        "file_move".to_string(),
        "terminal_persistence".to_string(),
        "pairing_v1".to_string(),
        "project_commands".to_string(),
        "remote_term_tracking".to_string(),
        "task_history".to_string(),
        "evidence".to_string(),
        "evolution".to_string(),
    ]
}

// ============================================================================
// ServerMessage 辅助构造方法
// ============================================================================

impl ServerMessage {
    /// 创建不带上下文的错误消息（向后兼容的快捷方式）
    pub fn make_error(code: impl Into<String>, message: impl Into<String>) -> Self {
        ServerMessage::Error {
            code: code.into(),
            message: message.into(),
            project: None,
            workspace: None,
            session_id: None,
            cycle_id: None,
        }
    }

    /// 创建带项目/工作区上下文的错误消息（多工作区场景使用）
    pub fn make_error_with_context(
        code: impl Into<String>,
        message: impl Into<String>,
        project: Option<String>,
        workspace: Option<String>,
        session_id: Option<String>,
        cycle_id: Option<String>,
    ) -> Self {
        ServerMessage::Error {
            code: code.into(),
            message: message.into(),
            project,
            workspace,
            session_id,
            cycle_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::context::AppError;
    use serde_json::json;

    #[test]
    fn test_parse_import_project() {
        let json = r#"{"type":"import_project","name":"ly_tech","path":"/Users/godbobo/work/projects/ly_tech"}"#;

        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::ImportProject { name, path }) => {
                assert_eq!(name, "ly_tech");
                assert_eq!(path, "/Users/godbobo/work/projects/ly_tech");
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_cancel_project_command_with_task_id() {
        let json = r#"{"type":"cancel_project_command","project":"demo","workspace":"default","command_id":"build","task_id":"task-1"}"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::CancelProjectCommand {
                project,
                workspace,
                command_id,
                task_id,
            }) => {
                assert_eq!(project, "demo");
                assert_eq!(workspace, "default");
                assert_eq!(command_id, "build");
                assert_eq!(task_id.as_deref(), Some("task-1"));
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_save_client_settings_without_workspace_todos() {
        let json = r#"{
            "type":"save_client_settings",
            "custom_commands":[],
            "workspace_shortcuts":{},
            "merge_ai_agent":"codex"
        }"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::SaveClientSettings {
                workspace_todos, ..
            }) => {
                assert!(workspace_todos.is_none());
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_save_client_settings_with_workspace_todos() {
        let json = r#"{
            "type":"save_client_settings",
            "custom_commands":[],
            "workspace_shortcuts":{},
            "workspace_todos":{
                "demo:default":[
                    {
                        "id":"todo-1",
                        "title":"实现核心逻辑",
                        "note":"先补协议",
                        "status":"in_progress",
                        "order":0,
                        "created_at_ms":1760000000000,
                        "updated_at_ms":1760000000001
                    }
                ]
            }
        }"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::SaveClientSettings {
                workspace_todos: Some(workspace_todos),
                ..
            }) => {
                assert_eq!(workspace_todos.len(), 1);
                assert_eq!(workspace_todos["demo:default"][0].status, "in_progress");
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_ai_session_messages_with_before_message_id() {
        let json = r#"{"type":"ai_session_messages","project_name":"demo","workspace_name":"default","ai_tool":"codex","session_id":"ses_1","before_message_id":"msg_42","limit":50}"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::AISessionMessages {
                project_name,
                workspace_name,
                ai_tool,
                session_id,
                before_message_id,
                limit,
            }) => {
                assert_eq!(project_name, "demo");
                assert_eq!(workspace_name, "default");
                assert_eq!(ai_tool, "codex");
                assert_eq!(session_id, "ses_1");
                assert_eq!(before_message_id.as_deref(), Some("msg_42"));
                assert_eq!(limit, Some(50));
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_ai_session_messages_with_negative_limit() {
        let json = r#"{"type":"ai_session_messages","project_name":"demo","workspace_name":"default","ai_tool":"codex","session_id":"ses_1","limit":-3}"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        match result {
            Ok(ClientMessage::AISessionMessages { limit, .. }) => {
                assert_eq!(limit, Some(-3));
            }
            Ok(other) => panic!("Unexpected message type: {:?}", other),
            Err(e) => panic!("Parse error: {}", e),
        }
    }

    #[test]
    fn test_parse_evo_start_workspace_should_reject_legacy_project_fields() {
        let json = r#"{"type":"evo_start_workspace","project_name":"demo","workspace_name":"default","priority":0,"loop_round_limit":3}"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_parse_evo_resume_workspace_should_reject_legacy_project_fields() {
        let json =
            r#"{"type":"evo_resume_workspace","project_name":"demo","workspace_name":"default"}"#;
        let result: Result<ClientMessage, _> = serde_json::from_str(json);
        assert!(result.is_err());
    }

    #[test]
    fn test_ai_session_messages_result_roundtrip_with_pagination_fields() {
        let message = ServerMessage::AISessionMessages {
            project_name: "demo".to_string(),
            workspace_name: "default".to_string(),
            ai_tool: "codex".to_string(),
            session_id: "ses_1".to_string(),
            before_message_id: Some("msg_42".to_string()),
            messages: vec![],
            has_more: true,
            next_before_message_id: Some("msg_21".to_string()),
            selection_hint: None,
            truncated: Some(true),
        };
        let encoded = rmp_serde::to_vec_named(&message).expect("encode ai_session_messages");
        let decoded: ServerMessage =
            rmp_serde::from_slice(&encoded).expect("decode ai_session_messages");
        match decoded {
            ServerMessage::AISessionMessages {
                before_message_id,
                has_more,
                next_before_message_id,
                truncated,
                ..
            } => {
                assert_eq!(before_message_id.as_deref(), Some("msg_42"));
                assert!(has_more);
                assert_eq!(next_before_message_id.as_deref(), Some("msg_21"));
                assert_eq!(truncated, Some(true));
            }
            other => panic!("Unexpected message type: {:?}", other),
        }
    }

    #[test]
    fn test_ai_session_list_result_roundtrip_with_pagination_fields() {
        let message = ServerMessage::AISessionListV2 {
            project_name: "demo".to_string(),
            workspace_name: "default".to_string(),
            filter_ai_tool: None,
            sessions: vec![ai::SessionInfo {
                project_name: "demo".to_string(),
                workspace_name: "default".to_string(),
                ai_tool: "codex".to_string(),
                id: "ses_1".to_string(),
                title: "实现分页".to_string(),
                updated_at: 123,
                session_origin: ai::AiSessionOrigin::EvolutionSystem,
            }],
            has_more: true,
            next_cursor: Some("cursor_1".to_string()),
        };
        let encoded = rmp_serde::to_vec_named(&message).expect("encode ai_session_list");
        let decoded: ServerMessage =
            rmp_serde::from_slice(&encoded).expect("decode ai_session_list");
        match decoded {
            ServerMessage::AISessionListV2 {
                filter_ai_tool,
                sessions,
                has_more,
                next_cursor,
                ..
            } => {
                assert_eq!(filter_ai_tool, None);
                assert_eq!(sessions.len(), 1);
                assert_eq!(sessions[0].ai_tool, "codex");
                assert!(matches!(
                    sessions[0].session_origin,
                    ai::AiSessionOrigin::EvolutionSystem
                ));
                assert!(has_more);
                assert_eq!(next_cursor.as_deref(), Some("cursor_1"));
            }
            other => panic!("Unexpected message type: {:?}", other),
        }
    }

    #[test]
    fn envelope_shapes_and_msgpack_roundtrip_are_stable() {
        let client_envelope = json!({
            "request_id": "test-123",
            "domain": "system",
            "action": "ping",
            "payload": {},
            "client_ts": 1234567890
        });
        assert_eq!(client_envelope["request_id"], "test-123");
        assert_eq!(client_envelope["domain"], "system");
        assert_eq!(client_envelope["action"], "ping");

        let server_envelope = json!({
            "seq": 2,
            "domain": "terminal",
            "action": "output_batch",
            "kind": "event",
            "payload": {"items": []},
            "server_ts": 1234567890
        });
        assert!(server_envelope.get("request_id").is_none());

        let encoded = rmp_serde::to_vec_named(&client_envelope).expect("encode should succeed");
        assert!(!encoded.is_empty());
        assert!(encoded.len() < 80);

        let decoded: serde_json::Value =
            rmp_serde::from_slice(&encoded).expect("decode should succeed");
        assert_eq!(decoded["request_id"], "test-123");
        assert_eq!(decoded["domain"], "system");
    }

    #[test]
    fn protocol_version_is_v8() {
        assert_eq!(PROTOCOL_VERSION, 8);
    }

    #[test]
    fn app_error_and_server_error_helpers_keep_context() {
        assert_eq!(
            AppError::ProjectNotFound("foo".into()).code(),
            "project_not_found"
        );
        assert_eq!(
            AppError::WorkspaceNotFound("bar".into()).code(),
            "workspace_not_found"
        );
        assert_eq!(AppError::Git("err".into()).code(), "git_error");
        assert_eq!(AppError::File("err".into()).code(), "file_error");
        assert_eq!(AppError::Internal("err".into()).code(), "internal_error");
        assert_eq!(AppError::Custom("err".into()).code(), "error");
        assert_eq!(AppError::AISession("err".into()).code(), "ai_session_error");
        assert_eq!(AppError::Evolution("err".into()).code(), "evolution_error");

        let contextual = AppError::AISession("session failed".into()).to_server_error_with_context(
            Some("myproject".to_string()),
            Some("feature-x".to_string()),
            Some("sess-123".to_string()),
            None,
        );
        match contextual {
            ServerMessage::Error {
                code,
                project,
                workspace,
                session_id,
                ..
            } => {
                assert_eq!(code, "ai_session_error");
                assert_eq!(project.as_deref(), Some("myproject"));
                assert_eq!(workspace.as_deref(), Some("feature-x"));
                assert_eq!(session_id.as_deref(), Some("sess-123"));
            }
            _ => panic!("Expected ServerMessage::Error"),
        }

        let helper = ServerMessage::make_error_with_context(
            "evolution_error",
            "evo failed",
            Some("proj".to_string()),
            Some("ws".to_string()),
            None,
            Some("cycle-abc".to_string()),
        );
        match helper {
            ServerMessage::Error {
                code,
                project,
                workspace,
                cycle_id,
                ..
            } => {
                assert_eq!(code, "evolution_error");
                assert_eq!(project.as_deref(), Some("proj"));
                assert_eq!(workspace.as_deref(), Some("ws"));
                assert_eq!(cycle_id.as_deref(), Some("cycle-abc"));
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn error_serialization_preserves_context_contract() {
        let plain = ServerMessage::make_error("internal_error", "something went wrong");
        let plain_json = serde_json::to_string(&plain).expect("serialize should succeed");
        assert!(!plain_json.contains("\"project\""));
        assert!(!plain_json.contains("\"workspace\""));
        assert!(!plain_json.contains("\"session_id\""));
        assert!(!plain_json.contains("\"cycle_id\""));
        assert!(plain_json.contains("\"internal_error\""));

        let contextual = ServerMessage::Error {
            code: "workspace_not_found".to_string(),
            message: "Workspace 'missing' not found in project 'demo'".to_string(),
            project: Some("demo".to_string()),
            workspace: Some("missing".to_string()),
            session_id: None,
            cycle_id: None,
        };
        let contextual_json = serde_json::to_string(&contextual).unwrap();
        let parsed: ServerMessage = serde_json::from_str(&contextual_json).unwrap();

        match parsed {
            ServerMessage::Error {
                code,
                project,
                workspace,
                ..
            } => {
                assert_eq!(code, "workspace_not_found");
                assert_eq!(project.as_deref(), Some("demo"));
                assert_eq!(workspace.as_deref(), Some("missing"));
            }
            _ => panic!("Expected ServerMessage::Error"),
        }
    }

    #[test]
    fn log_entry_new_fields_remain_backward_compatible() {
        let json_with_error_code = serde_json::json!({
            "type": "log_entry",
            "level": "ERROR",
            "source": "swift",
            "category": "ws",
            "msg": "WebSocket receive failed",
            "detail": "timeout",
            "error_code": "ws_receive_error",
            "project": "myproject",
            "workspace": "default",
            "session_id": null,
            "cycle_id": null
        });

        let msg: ClientMessage =
            serde_json::from_value(json_with_error_code).expect("deserialize should succeed");
        match msg {
            ClientMessage::LogEntry {
                level,
                error_code,
                project,
                workspace,
                ..
            } => {
                assert_eq!(level, "ERROR");
                assert_eq!(error_code.as_deref(), Some("ws_receive_error"));
                assert_eq!(project.as_deref(), Some("myproject"));
                assert_eq!(workspace.as_deref(), Some("default"));
            }
            _ => panic!("Expected ClientMessage::LogEntry"),
        }

        let json_old_format = serde_json::json!({
            "type": "log_entry",
            "level": "INFO",
            "source": "swift",
            "msg": "App started"
        });

        let msg: ClientMessage =
            serde_json::from_value(json_old_format).expect("old format deserialize should succeed");
        match msg {
            ClientMessage::LogEntry {
                level,
                error_code,
                project,
                workspace,
                session_id,
                cycle_id,
                ..
            } => {
                assert_eq!(level, "INFO");
                assert!(error_code.is_none());
                assert!(project.is_none());
                assert!(workspace.is_none());
                assert!(session_id.is_none());
                assert!(cycle_id.is_none());
            }
            _ => panic!("Expected ClientMessage::LogEntry"),
        }
    }
}
