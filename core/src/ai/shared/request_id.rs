use serde_json::Value;

pub fn request_id_key(id: &Value) -> String {
    match id {
        Value::String(s) => format!("s:{}", s),
        Value::Number(n) => format!("n:{}", n),
        _ => format!("j:{}", id),
    }
}
