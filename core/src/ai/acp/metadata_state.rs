fn normalized_update_token(raw: &str) -> String {
    raw.trim()
        .to_lowercase()
        .replace('-', "_")
        .replace(' ', "_")
}

pub(crate) fn normalize_mode_name(raw: &str) -> String {
    normalized_update_token(raw)
}

pub(crate) fn normalize_non_empty_token(raw: &str) -> Option<String> {
    let token = raw.trim();
    if token.is_empty() {
        None
    } else {
        Some(token.to_string())
    }
}

pub(crate) fn normalize_current_mode_update(raw: &str) -> bool {
    let normalized = normalized_update_token(raw);
    normalized == "current_mode_update" || normalized == "currentmodeupdate"
}

pub(crate) fn is_config_option_update(raw: &str) -> bool {
    let normalized = normalized_update_token(raw);
    normalized == "config_option_update" || normalized == "configoptionupdate"
}

pub(crate) fn is_config_options_update(raw: &str) -> bool {
    let normalized = normalized_update_token(raw);
    normalized == "config_options_update" || normalized == "configoptionsupdate"
}

pub(crate) fn is_available_commands_update(raw: &str) -> bool {
    let normalized = normalized_update_token(raw);
    matches!(
        normalized.as_str(),
        "available_commands_update"
            | "availablecommandsupdate"
            | "available_command_update"
            | "availablecommandupdate"
    )
}
