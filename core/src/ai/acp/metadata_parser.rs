use crate::ai::acp::client::{
    AcpConfigOptionChoice, AcpConfigOptionGroup, AcpConfigOptionInfo, AcpModeInfo, AcpModelInfo,
    AcpSessionMetadata,
};
use crate::ai::shared::json_search::{
    canonical_meta_key, find_scalar_by_keys, json_value_to_trimmed_string, normalize_optional_token,
};
use serde_json::Value;
use std::collections::HashMap;
use tracing::{debug, warn};

fn rows_from_key(root: &Value, key: &str) -> Vec<Value> {
    if let Some(arr) = root.get(key).and_then(|v| v.as_array()) {
        return arr.clone();
    }
    if let Some(obj) = root.get(key).and_then(|v| v.as_object()) {
        return obj.values().cloned().collect();
    }
    Vec::new()
}

fn rows_from_candidates(root: &Value, keys: &[&str]) -> Vec<Value> {
    for key in keys {
        let rows = rows_from_key(root, key);
        if !rows.is_empty() {
            return rows;
        }
    }
    if let Some(arr) = root.as_array() {
        return arr.clone();
    }
    Vec::new()
}

fn normalize_current_model_id(raw: Option<String>, models: &[AcpModelInfo]) -> Option<String> {
    let current = normalize_optional_token(raw)?;
    if models.is_empty() {
        return Some(current);
    }

    if let Some(found) = models
        .iter()
        .find(|row| row.id == current || row.id.eq_ignore_ascii_case(&current))
    {
        return Some(found.id.clone());
    }

    if let Some((_, suffix)) = current.split_once('/') {
        let normalized_suffix = suffix.trim();
        if !normalized_suffix.is_empty() {
            if let Some(found) = models.iter().find(|row| {
                row.id == normalized_suffix || row.id.eq_ignore_ascii_case(normalized_suffix)
            }) {
                return Some(found.id.clone());
            }
        }
    }

    Some(current)
}

fn normalize_current_mode_id(raw: Option<String>, modes: &[AcpModeInfo]) -> Option<String> {
    let current = normalize_optional_token(raw)?;
    if modes.is_empty() {
        return Some(current);
    }

    if let Some(found) = modes
        .iter()
        .find(|row| row.id == current || row.id.eq_ignore_ascii_case(&current))
    {
        return Some(found.id.clone());
    }

    Some(current)
}

fn find_object_by_keys(value: &Value, keys: &[&str]) -> Option<serde_json::Map<String, Value>> {
    let target = keys
        .iter()
        .map(|key| canonical_meta_key(key))
        .collect::<Vec<_>>();
    let mut stack = vec![value];
    let mut visited = 0usize;
    const MAX_VISITS: usize = 400;

    while let Some(node) = stack.pop() {
        if visited >= MAX_VISITS {
            break;
        }
        visited += 1;
        match node {
            Value::Object(map) => {
                for (k, v) in map {
                    let canonical = canonical_meta_key(k);
                    if target.iter().any(|key| key == &canonical) {
                        if let Some(found) = v.as_object() {
                            return Some(found.clone());
                        }
                    }
                    if matches!(v, Value::Object(_) | Value::Array(_)) {
                        stack.push(v);
                    }
                }
            }
            Value::Array(arr) => {
                for item in arr {
                    if matches!(item, Value::Object(_) | Value::Array(_)) {
                        stack.push(item);
                    }
                }
            }
            _ => {}
        }
    }

    None
}

fn parse_config_option_choice(value: &Value) -> Option<AcpConfigOptionChoice> {
    let obj = value.as_object()?;
    let choice_value = obj
        .get("value")
        .or_else(|| obj.get("id"))
        .or_else(|| obj.get("optionId"))
        .or_else(|| obj.get("option_id"))
        .cloned()?;
    let label = obj
        .get("label")
        .and_then(|v| v.as_str())
        .or_else(|| obj.get("name").and_then(|v| v.as_str()))
        .or_else(|| choice_value.as_str())
        .unwrap_or("option")
        .to_string();
    let description = obj
        .get("description")
        .and_then(|v| v.as_str())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty());
    Some(AcpConfigOptionChoice {
        value: choice_value,
        label,
        description,
    })
}

fn parse_config_option_option_groups(
    value: Option<&Value>,
) -> (Vec<AcpConfigOptionChoice>, Vec<AcpConfigOptionGroup>) {
    let mut options = Vec::new();
    let mut option_groups = Vec::new();
    let Some(items) = value.and_then(|v| v.as_array()) else {
        return (options, option_groups);
    };

    for item in items {
        if let Some(obj) = item.as_object() {
            let grouped = obj
                .get("options")
                .and_then(|v| v.as_array())
                .or_else(|| obj.get("choices").and_then(|v| v.as_array()))
                .or_else(|| obj.get("items").and_then(|v| v.as_array()));
            if let Some(group_items) = grouped {
                let group_options = group_items
                    .iter()
                    .filter_map(parse_config_option_choice)
                    .collect::<Vec<_>>();
                if !group_options.is_empty() {
                    let label = obj
                        .get("label")
                        .and_then(|v| v.as_str())
                        .or_else(|| obj.get("name").and_then(|v| v.as_str()))
                        .or_else(|| obj.get("groupLabel").and_then(|v| v.as_str()))
                        .or_else(|| obj.get("group_label").and_then(|v| v.as_str()))
                        .unwrap_or("group")
                        .to_string();
                    option_groups.push(AcpConfigOptionGroup {
                        label,
                        options: group_options,
                    });
                }
                continue;
            }
        }

        if let Some(choice) = parse_config_option_choice(item) {
            options.push(choice);
        }
    }

    (options, option_groups)
}

fn parse_config_option_info(value: Value) -> Option<AcpConfigOptionInfo> {
    let obj = value.as_object()?;
    let option_id = obj
        .get("optionId")
        .and_then(|v| v.as_str())
        .or_else(|| obj.get("option_id").and_then(|v| v.as_str()))
        .or_else(|| obj.get("id").and_then(|v| v.as_str()))
        .or_else(|| obj.get("key").and_then(|v| v.as_str()))
        .or_else(|| obj.get("name").and_then(|v| v.as_str()))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())?;
    let category = obj
        .get("category")
        .and_then(|v| v.as_str())
        .or_else(|| obj.get("kind").and_then(|v| v.as_str()))
        .or_else(|| obj.get("group").and_then(|v| v.as_str()))
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let name = obj
        .get("name")
        .and_then(|v| v.as_str())
        .or_else(|| obj.get("label").and_then(|v| v.as_str()))
        .or_else(|| obj.get("title").and_then(|v| v.as_str()))
        .unwrap_or(&option_id)
        .to_string();
    let description = obj
        .get("description")
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    let current_value = obj
        .get("currentValue")
        .or_else(|| obj.get("current_value"))
        .or_else(|| obj.get("value"))
        .or_else(|| obj.get("selectedValue"))
        .or_else(|| obj.get("selected_value"))
        .cloned()
        .filter(|v| !v.is_null());
    let (options, option_groups) = parse_config_option_option_groups(
        obj.get("options")
            .or_else(|| obj.get("choices"))
            .or_else(|| obj.get("values")),
    );
    Some(AcpConfigOptionInfo {
        option_id,
        category,
        name,
        description,
        current_value,
        options,
        option_groups,
        raw: Some(Value::Object(obj.clone())),
    })
}

fn parse_config_options(value: &Value) -> Vec<AcpConfigOptionInfo> {
    let mut rows = Vec::<Value>::new();
    for key in [
        "sessionConfigOptions",
        "session_config_options",
        "configOptions",
        "config_options",
        "options",
    ] {
        let found = rows_from_key(value, key);
        if !found.is_empty() {
            rows = found;
            break;
        }
    }

    if rows.is_empty() {
        if let Some(found) = find_object_by_keys(
            value,
            &[
                "sessionConfigOptions",
                "session_config_options",
                "configOptions",
                "config_options",
            ],
        ) {
            rows = found.into_values().collect::<Vec<_>>();
        }
    }

    let mut options = rows
        .into_iter()
        .filter_map(parse_config_option_info)
        .collect::<Vec<_>>();
    options.sort_by(|a, b| a.option_id.cmp(&b.option_id));
    options
}

fn parse_config_values(value: &Value) -> HashMap<String, Value> {
    let mut out = HashMap::<String, Value>::new();
    for key in [
        "sessionConfig",
        "session_config",
        "configValues",
        "config_values",
        "selectedConfigOptions",
        "selected_config_options",
        "currentConfigOptions",
        "current_config_options",
        "config",
    ] {
        let Some(found) = find_object_by_keys(value, &[key]) else {
            continue;
        };
        for (option_id, option_value) in found {
            if option_id.trim().is_empty() || option_value.is_null() {
                continue;
            }
            out.insert(option_id, option_value);
        }
    }
    out
}

fn normalize_config_category(category: Option<&str>, option_id: &str) -> String {
    let from_category = category
        .map(|v| v.trim().to_lowercase())
        .filter(|v| !v.is_empty());
    if let Some(category) = from_category {
        return category;
    }
    option_id.trim().to_lowercase()
}

fn extract_config_value_as_id(value: &Value) -> Option<String> {
    if let Some(raw) = value.as_str() {
        let trimmed = raw.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    let obj = value.as_object()?;
    obj.get("id")
        .or_else(|| obj.get("modeId"))
        .or_else(|| obj.get("mode_id"))
        .or_else(|| obj.get("modelId"))
        .or_else(|| obj.get("model_id"))
        .or_else(|| obj.get("value"))
        .and_then(json_value_to_trimmed_string)
}

pub(crate) fn parse_session_metadata(value: &Value) -> AcpSessionMetadata {
    let models_root = value.get("models").unwrap_or(value);
    let modes_root = value.get("modes").unwrap_or(value);

    let models = rows_from_candidates(models_root, &["availableModels", "available_models"])
        .into_iter()
        .filter_map(|row| {
            let id = row
                .get("modelId")
                .and_then(|v| v.as_str())
                .or_else(|| row.get("model_id").and_then(|v| v.as_str()))
                .or_else(|| row.get("id").and_then(|v| v.as_str()))
                .or_else(|| row.get("model").and_then(|v| v.as_str()))?
                .to_string();
            let name = row
                .get("name")
                .and_then(|v| v.as_str())
                .or_else(|| row.get("displayName").and_then(|v| v.as_str()))
                .or_else(|| row.get("display_name").and_then(|v| v.as_str()))
                .unwrap_or(&id)
                .to_string();
            let supports_image_input = row
                .get("inputModalities")
                .and_then(|v| v.as_array())
                .or_else(|| row.get("input_modalities").and_then(|v| v.as_array()))
                .or_else(|| {
                    row.get("modalities")
                        .and_then(|v| v.get("input"))
                        .and_then(|v| v.as_array())
                })
                .map(|arr| {
                    arr.iter().any(|it| {
                        it.as_str()
                            .map(|s| s.eq_ignore_ascii_case("image"))
                            .unwrap_or(false)
                    })
                })
                .unwrap_or(true);
            Some(AcpModelInfo {
                id,
                name,
                supports_image_input,
            })
        })
        .collect::<Vec<_>>();
    let current_model_id = normalize_current_model_id(
        models_root
            .get("currentModelId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                models_root
                    .get("current_model_id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                find_scalar_by_keys(
                    models_root,
                    &[
                        "currentModelId",
                        "current_model_id",
                        "selectedModelId",
                        "selected_model_id",
                    ],
                )
            })
            .or_else(|| {
                models_root
                    .get("currentModel")
                    .and_then(|v| {
                        v.get("modelId")
                            .or_else(|| v.get("modelID"))
                            .or_else(|| v.get("id"))
                    })
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value
                    .get("currentModel")
                    .and_then(|v| {
                        v.get("modelId")
                            .or_else(|| v.get("modelID"))
                            .or_else(|| v.get("id"))
                    })
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value.get("model").and_then(|v| {
                    v.as_str().map(|s| s.to_string()).or_else(|| {
                        v.get("modelId")
                            .or_else(|| v.get("modelID"))
                            .or_else(|| v.get("id"))
                            .and_then(|it| it.as_str())
                            .map(|s| s.to_string())
                    })
                })
            }),
        &models,
    );

    let modes = rows_from_candidates(modes_root, &["availableModes", "available_modes"])
        .into_iter()
        .filter_map(|row| {
            let id = row
                .get("id")
                .and_then(|v| v.as_str())
                .or_else(|| row.get("modeId").and_then(|v| v.as_str()))
                .or_else(|| row.get("mode_id").and_then(|v| v.as_str()))
                .or_else(|| row.get("mode").and_then(|v| v.as_str()))
                .or_else(|| row.get("name").and_then(|v| v.as_str()))?
                .to_string();
            let name = row
                .get("name")
                .and_then(|v| v.as_str())
                .unwrap_or(&id)
                .to_string();
            let description = row
                .get("description")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            Some(AcpModeInfo {
                id,
                name,
                description,
            })
        })
        .collect::<Vec<_>>();
    let current_mode_id = normalize_current_mode_id(
        modes_root
            .get("currentModeId")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string())
            .or_else(|| {
                modes_root
                    .get("current_mode_id")
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                find_scalar_by_keys(
                    modes_root,
                    &[
                        "currentModeId",
                        "current_mode_id",
                        "selectedModeId",
                        "selected_mode_id",
                    ],
                )
            })
            .or_else(|| {
                modes_root
                    .get("currentMode")
                    .and_then(|v| {
                        v.get("modeId")
                            .or_else(|| v.get("modeID"))
                            .or_else(|| v.get("id"))
                    })
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value
                    .get("currentMode")
                    .and_then(|v| {
                        v.get("modeId")
                            .or_else(|| v.get("modeID"))
                            .or_else(|| v.get("id"))
                    })
                    .and_then(|v| v.as_str())
                    .map(|s| s.to_string())
            })
            .or_else(|| {
                value.get("mode").and_then(|v| {
                    v.as_str().map(|s| s.to_string()).or_else(|| {
                        v.get("modeId")
                            .or_else(|| v.get("modeID"))
                            .or_else(|| v.get("id"))
                            .and_then(|it| it.as_str())
                            .map(|s| s.to_string())
                    })
                })
            }),
        &modes,
    );

    let config_options = parse_config_options(value);
    let mut config_values = parse_config_values(value);
    for option in &config_options {
        if let Some(current_value) = option.current_value.clone() {
            config_values.insert(option.option_id.clone(), current_value);
        }
    }

    let current_mode_id = if current_mode_id.is_some() {
        current_mode_id
    } else {
        let from_config = config_options.iter().find_map(|option| {
            let category = normalize_config_category(option.category.as_deref(), &option.option_id);
            if category != "mode" {
                return None;
            }
            let value = option
                .current_value
                .as_ref()
                .or_else(|| config_values.get(&option.option_id))?;
            extract_config_value_as_id(value)
        });
        normalize_current_mode_id(from_config, &modes)
    };

    let current_model_id = if current_model_id.is_some() {
        current_model_id
    } else {
        let from_config = config_options.iter().find_map(|option| {
            let category = normalize_config_category(option.category.as_deref(), &option.option_id);
            if category != "model" {
                return None;
            }
            let value = option
                .current_value
                .as_ref()
                .or_else(|| config_values.get(&option.option_id))?;
            extract_config_value_as_id(value)
        });
        normalize_current_model_id(from_config, &models)
    };

    if models.is_empty()
        && modes.is_empty()
        && config_options.is_empty()
        && current_model_id.is_none()
        && current_mode_id.is_none()
    {
        let top_keys = value
            .as_object()
            .map(|obj| obj.keys().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        let snippet = serde_json::to_string(value)
            .unwrap_or_default()
            .chars()
            .take(600)
            .collect::<String>();
        warn!(
            "ACP session metadata parse empty: top_level_keys={:?}, raw_snippet={}",
            top_keys, snippet
        );
    } else {
        debug!(
            "ACP session metadata parsed: models_count={}, modes_count={}, config_options_count={}, current_model_id={:?}, current_mode_id={:?}",
            models.len(),
            modes.len(),
            config_options.len(),
            current_model_id,
            current_mode_id
        );
    }

    AcpSessionMetadata {
        models,
        current_model_id,
        modes,
        current_mode_id,
        config_options,
        config_values,
    }
}
