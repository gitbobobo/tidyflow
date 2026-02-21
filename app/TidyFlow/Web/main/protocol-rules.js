/**
 * 自动生成协议 action 规则（schema 驱动）。
 * 生成器会替换标记块内内容，请勿手改。
 */
(function () {
  "use strict";

  window.TidyFlowApp = window.TidyFlowApp || {};
  const TF = window.TidyFlowApp;

  // BEGIN AUTO-GENERATED: protocol_action_rules
  TF.protocolExactRules = [
        ["system", "ping"],
        ["terminal", "spawn_terminal"],
        ["terminal", "kill_terminal"],
        ["terminal", "input"],
        ["terminal", "resize"],
        ["file", "clipboard_image_upload"],
        ["git", "cancel_ai_task"],
  ];

  TF.protocolPrefixRules = [
        ["terminal", "term_"],
        ["file", "file_"],
        ["file", "watch_"],
        ["git", "git_"],
        ["project", "list_"],
        ["project", "select_"],
        ["project", "import_"],
        ["project", "create_"],
        ["project", "remove_"],
        ["project", "project_"],
        ["project", "workspace_"],
        ["project", "save_project_commands"],
        ["project", "run_project_command"],
        ["project", "cancel_project_command"],
        ["lsp", "lsp_"],
        ["log", "log_"],
        ["ai", "ai_"],
        ["evolution", "evo_"],
  ];

  TF.protocolContainsRules = [
        ["settings", "client_settings"],
  ];
  // END AUTO-GENERATED: protocol_action_rules

  TF.domainForAction = function (action) {
    for (const [domain, value] of TF.protocolExactRules || []) {
      if (action === value) return domain;
    }
    for (const [domain, value] of TF.protocolPrefixRules || []) {
      if (action.startsWith(value)) return domain;
    }
    for (const [domain, value] of TF.protocolContainsRules || []) {
      if (action.includes(value)) return domain;
    }
    return "misc";
  };
})();
