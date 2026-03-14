import TidyFlowShared

// 已迁移到 TidyFlowShared/Networking/WSClient+Send.swift。
// 此文件不再参与平台 target 编译，仅保留协议规则镜像供护栏脚本校验。

    // BEGIN AUTO-GENERATED: protocol_action_rules
    private var protocolExactRules: [(domain: String, action: String)] {
        [
        ("system", "ping"),
        ("terminal", "spawn_terminal"),
        ("terminal", "kill_terminal"),
        ("terminal", "input"),
        ("terminal", "resize"),
        ("file", "clipboard_image_upload"),
        ("git", "cancel_ai_task"),
        ("project", "save_template"),
        ("project", "delete_template"),
        ("project", "export_template"),
        ("project", "import_template"),
        ("project", "templates"),
        ("node", "node_refresh_network"),
        ]
    }

    private var protocolPrefixRules: [(domain: String, prefix: String)] {
        [
        ("terminal", "term_"),
        ("file", "file_"),
        ("file", "watch_"),
        ("git", "git_"),
        ("project", "list_"),
        ("project", "select_"),
        ("project", "import_"),
        ("project", "create_"),
        ("project", "remove_"),
        ("project", "project_"),
        ("project", "workspace_"),
        ("project", "save_project_commands"),
        ("project", "run_project_command"),
        ("project", "cancel_project_command"),
        ("project", "template_"),
        ("node", "node_"),
        ("ai", "ai_"),
        ("evolution", "evo_"),
        ("git", "git_conflict_"),
        ("health", "health_"),
        ]
    }

    private var protocolContainsRules: [(domain: String, needle: String)] {
        [
        ("settings", "client_settings"),
        ]
    }
    // END AUTO-GENERATED: protocol_action_rules

