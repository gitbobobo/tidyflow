use serde_json::Value;

#[derive(Debug, Clone, Default)]
pub struct AiSessionContextUsage {
    pub context_remaining_percent: Option<f64>,
}

fn canonical_key(raw: &str) -> String {
    raw.chars()
        .filter(|ch| *ch != '_' && *ch != '-')
        .flat_map(|ch| ch.to_lowercase())
        .collect::<String>()
}

fn parse_number(value: &Value) -> Option<f64> {
    match value {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse::<f64>().ok(),
        _ => None,
    }
}

fn normalize_percent(value: f64) -> Option<f64> {
    if !value.is_finite() {
        return None;
    }
    let percent = if (0.0..=1.0).contains(&value) {
        value * 100.0
    } else {
        value
    };
    Some(percent.clamp(0.0, 100.0))
}

fn find_first_number_by_keys(value: &Value, keys: &[&str]) -> Option<f64> {
    let target = keys.iter().map(|k| canonical_key(k)).collect::<Vec<_>>();
    let mut stack = vec![value];

    while let Some(node) = stack.pop() {
        match node {
            Value::Object(map) => {
                for (k, v) in map {
                    let key = canonical_key(k);
                    if target.iter().any(|t| t == &key) {
                        if let Some(number) = parse_number(v) {
                            return Some(number);
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

fn object_number_by_keys<'a>(map: &'a serde_json::Map<String, Value>, keys: &[&str]) -> Option<f64> {
    let target = keys.iter().map(|k| canonical_key(k)).collect::<Vec<_>>();
    for (k, v) in map {
        let key = canonical_key(k);
        if target.iter().any(|t| t == &key) {
            if let Some(number) = parse_number(v) {
                return Some(number);
            }
        }
    }
    None
}

fn find_ratio_from_objects(value: &Value) -> Option<f64> {
    const REMAINING_KEYS: &[&str] = &[
        "remaining_tokens",
        "tokens_remaining",
        "remaining",
        "available_tokens",
        "context_remaining_tokens",
    ];
    const USED_KEYS: &[&str] = &[
        "used_tokens",
        "consumed_tokens",
        "input_tokens",
        "prompt_tokens",
        "total_used_tokens",
        "used",
    ];
    const MAX_KEYS: &[&str] = &[
        "max_tokens",
        "context_window",
        "context_window_tokens",
        "token_limit",
        "context_limit",
        "total_tokens",
        "limit",
    ];

    let mut stack = vec![value];
    while let Some(node) = stack.pop() {
        match node {
            Value::Object(map) => {
                let remaining = object_number_by_keys(map, REMAINING_KEYS);
                let used = object_number_by_keys(map, USED_KEYS);
                let max = object_number_by_keys(map, MAX_KEYS);

                if let (Some(remaining), Some(max)) = (remaining, max) {
                    if max > 0.0 {
                        return normalize_percent((remaining / max) * 100.0);
                    }
                }
                if let (Some(used), Some(max)) = (used, max) {
                    if max > 0.0 {
                        return normalize_percent((1.0 - used / max) * 100.0);
                    }
                }

                for v in map.values() {
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

pub fn extract_context_remaining_percent(value: &Value) -> Option<f64> {
    const PERCENT_KEYS: &[&str] = &[
        "context_remaining_percent",
        "remaining_context_percent",
        "remaining_percent",
        "remaining_pct",
        "context_window_remaining_percent",
    ];

    if let Some(percent) = find_first_number_by_keys(value, PERCENT_KEYS) {
        return normalize_percent(percent);
    }
    find_ratio_from_objects(value)
}

#[cfg(test)]
mod tests {
    use super::extract_context_remaining_percent;

    #[test]
    fn parse_direct_percent() {
        let value = serde_json::json!({"context_remaining_percent": 72.5});
        assert_eq!(extract_context_remaining_percent(&value), Some(72.5));
    }

    #[test]
    fn parse_fraction_percent() {
        let value = serde_json::json!({"remaining_percent": 0.42});
        assert_eq!(extract_context_remaining_percent(&value), Some(42.0));
    }

    #[test]
    fn parse_remaining_and_max() {
        let value = serde_json::json!({"usage": {"remaining_tokens": 6000, "max_tokens": 12000}});
        assert_eq!(extract_context_remaining_percent(&value), Some(50.0));
    }

    #[test]
    fn parse_used_and_max() {
        let value = serde_json::json!({"usage": {"used_tokens": 3000, "max_tokens": 12000}});
        assert_eq!(extract_context_remaining_percent(&value), Some(75.0));
    }
}
