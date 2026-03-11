use crate::ai::context_usage::extract_context_remaining_percent;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionTime {
    #[serde(default)]
    pub created: i64,
    #[serde(default)]
    pub updated: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionResponse {
    pub id: String,
    pub title: String,
    /// OpenCode 新版会把目录放在 session 上，用于区分不同工作目录的会话。
    #[serde(default)]
    pub directory: Option<String>,
    /// 新版时间字段：{ time: { created, updated } }
    #[serde(default)]
    pub time: Option<SessionTime>,
    /// 旧版兼容字段（若存在则使用）；新版通常不返回 updatedAt。
    #[serde(default, alias = "updatedAt", alias = "updated_at")]
    pub updated_at: i64,
    /// 透传未知字段，便于后续从真实接口数据里提取会话级配置（model/agent）。
    #[serde(flatten, default)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

impl SessionResponse {
    pub(crate) fn effective_updated_at(&self) -> i64 {
        if let Some(t) = &self.time {
            if t.updated > 0 {
                return t.updated;
            }
        }
        self.updated_at
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateSessionRequest {
    pub title: String,
}

/// OpenCode Bus 事件（SSE `/event` 端点返回的格式）
#[derive(Debug, Clone, Deserialize)]
pub struct BusEvent {
    #[serde(rename = "type")]
    pub event_type: String,
    #[serde(default)]
    pub properties: serde_json::Value,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SessionListResponse {
    pub sessions: Vec<SessionResponse>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SessionStatusItem {
    #[serde(rename = "type")]
    pub status_type: String,
    #[serde(flatten, default)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

impl SessionStatusItem {
    pub fn context_remaining_percent(&self) -> Option<f64> {
        let value = serde_json::json!({
            "type": self.status_type,
            "extra": self.extra,
        });
        extract_context_remaining_percent(&value)
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct GlobalBusEventEnvelope {
    #[serde(default)]
    pub directory: Option<String>,
    pub payload: BusEvent,
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProviderResponse {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    /// models 可能是数组或 Record<id, model>
    #[serde(default)]
    pub models: serde_json::Value,
}

impl ProviderResponse {
    /// 将 models（可能是 dict 或 array）统一转为 Vec
    pub fn models_vec(&self) -> Vec<ProviderModelResponse> {
        if let Some(obj) = self.models.as_object() {
            obj.values()
                .filter_map(|v| serde_json::from_value(v.clone()).ok())
                .collect()
        } else if let Some(arr) = self.models.as_array() {
            arr.iter()
                .filter_map(|v| serde_json::from_value(v.clone()).ok())
                .collect()
        } else {
            vec![]
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct ProviderModelResponse {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub name: String,
    #[serde(default, rename = "providerID")]
    pub provider_id: String,
    /// 仅展示 active 模型
    #[serde(default)]
    pub status: Option<String>,
    /// OpenCode Provider.Model.capabilities（新协议）
    #[serde(default)]
    pub capabilities: Option<ProviderModelCapabilitiesResponse>,
    /// models.dev modalities（旧字段兜底）
    #[serde(default)]
    pub modalities: Option<ProviderModelModalitiesResponse>,
    /// 模型限制信息（例如 limit.context）
    #[serde(default)]
    pub limit: Option<serde_json::Value>,
    /// 模型变体配置（OpenCode 使用变体表达 reasoning effort 等能力）
    #[serde(default)]
    pub variants: Option<std::collections::HashMap<String, serde_json::Value>>,
}

impl ProviderModelResponse {
    pub fn supports_image_input(&self) -> bool {
        if let Some(cap) = &self.capabilities {
            if cap.input.image || cap.attachment {
                return true;
            }
        }
        if let Some(modalities) = &self.modalities {
            return modalities
                .input
                .iter()
                .any(|m| m.eq_ignore_ascii_case("image"));
        }
        false
    }

    pub fn variants_vec(&self) -> Vec<String> {
        let Some(variants) = &self.variants else {
            return Vec::new();
        };

        let mut values = variants
            .iter()
            .filter_map(|(key, value)| {
                let trimmed = key.trim();
                if trimmed.is_empty() {
                    return None;
                }
                let disabled = value
                    .as_object()
                    .and_then(|obj| obj.get("disabled"))
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                if disabled {
                    return None;
                }
                Some(trimmed.to_string())
            })
            .collect::<Vec<_>>();
        values.sort();
        values
    }
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelCapabilitiesResponse {
    #[serde(default)]
    pub attachment: bool,
    #[serde(default)]
    pub input: ProviderModelInputCapabilitiesResponse,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelInputCapabilitiesResponse {
    #[serde(default)]
    pub image: bool,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct ProviderModelModalitiesResponse {
    #[serde(default)]
    pub input: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentResponse {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default)]
    pub color: Option<String>,
    #[serde(default)]
    pub hidden: Option<bool>,
    /// agent 默认模型 { providerID, modelID }
    #[serde(default)]
    pub model: Option<AgentDefaultModel>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct CommandResponse {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct AgentDefaultModel {
    #[serde(default, rename = "providerID")]
    pub provider_id: String,
    #[serde(default, rename = "modelID")]
    pub model_id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MessageEnvelope {
    pub info: MessageInfo,
    #[serde(default)]
    pub parts: Vec<PartEnvelope>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct MessageInfo {
    pub id: String,
    #[serde(default)]
    pub role: String,
    #[serde(rename = "createdAt", default)]
    pub created_at: Option<i64>,
    #[serde(default)]
    pub agent: Option<String>,
    #[serde(default)]
    pub mode: Option<String>,
    #[serde(default, rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(default, rename = "modelID")]
    pub model_id: Option<String>,
    #[serde(default)]
    pub model: Option<MessageModelSelection>,
    #[serde(flatten)]
    pub extra: std::collections::HashMap<String, serde_json::Value>,
}

#[derive(Debug, Clone, Deserialize, Default)]
pub struct MessageModelSelection {
    #[serde(default, rename = "providerID")]
    pub provider_id: Option<String>,
    #[serde(default, rename = "modelID")]
    pub model_id: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PartEnvelope {
    pub id: String,
    #[serde(rename = "type")]
    pub part_type: String,
    #[serde(default)]
    pub text: Option<String>,
    #[serde(default)]
    pub mime: Option<String>,
    #[serde(default)]
    pub filename: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub synthetic: Option<bool>,
    #[serde(default)]
    pub ignored: Option<bool>,
    #[serde(default)]
    pub source: Option<serde_json::Value>,
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub tool: Option<String>,
    #[serde(rename = "callID", default)]
    pub call_id: Option<String>,
    #[serde(default)]
    pub state: Option<serde_json::Value>,
    #[serde(default)]
    pub metadata: Option<serde_json::Value>,
}

#[cfg(test)]
mod tests {
    use super::ProviderModelResponse;

    #[test]
    fn variants_vec_filters_disabled_and_empty_keys() {
        let model: ProviderModelResponse = serde_json::from_value(serde_json::json!({
            "id": "gpt-5",
            "name": "GPT-5",
            "providerID": "openai",
            "variants": {
                "high": {},
                "low": { "disabled": false },
                "": {},
                "legacy": { "disabled": true }
            }
        }))
        .expect("model response should parse");

        assert_eq!(
            model.variants_vec(),
            vec!["high".to_string(), "low".to_string()]
        );
    }
}
