use std::collections::{HashMap, HashSet};

use chrono::{DateTime, Utc};

use super::types::{LspLanguage, LspSeverity, WorkspaceDiagnostic};

/// 以 (language, uri) 为键存储最新诊断，便于服务端按增量更新
#[derive(Debug, Default)]
pub struct DiagnosticsStore {
    by_language_uri: HashMap<(LspLanguage, String), Vec<WorkspaceDiagnostic>>,
    updated_at: Option<DateTime<Utc>>,
}

impl DiagnosticsStore {
    pub fn update(
        &mut self,
        language: LspLanguage,
        uri: String,
        diagnostics: Vec<WorkspaceDiagnostic>,
    ) {
        self.by_language_uri.insert((language, uri), diagnostics);
        self.updated_at = Some(Utc::now());
    }

    pub fn clear_language(&mut self, language: LspLanguage) {
        self.by_language_uri
            .retain(|(lang, _), _| *lang != language);
        self.updated_at = Some(Utc::now());
    }

    pub fn all_sorted(&self) -> Vec<WorkspaceDiagnostic> {
        let mut dedup = HashSet::new();
        let mut items: Vec<WorkspaceDiagnostic> = Vec::new();

        for v in self.by_language_uri.values() {
            for item in v {
                let key = item.dedupe_key();
                if dedup.insert(key) {
                    items.push(item.clone());
                }
            }
        }

        items.sort_by(|a, b| {
            b.severity
                .rank()
                .cmp(&a.severity.rank())
                .then_with(|| a.path.cmp(&b.path))
                .then_with(|| a.line.cmp(&b.line))
                .then_with(|| a.column.cmp(&b.column))
                .then_with(|| a.message.cmp(&b.message))
        });
        items
    }

    pub fn highest_severity(&self) -> Option<LspSeverity> {
        self.by_language_uri
            .values()
            .flat_map(|v| v.iter().map(|d| d.severity))
            .max_by_key(|s| s.rank())
    }

    pub fn updated_at_rfc3339(&self) -> Option<String> {
        self.updated_at
            .map(|t| t.to_rfc3339_opts(chrono::SecondsFormat::Secs, true))
    }
}
