//! Project configuration parsing (.tidyflow.toml)

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::Path;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ConfigError {
    #[error("Config file not found: {0}")]
    NotFound(String),
    #[error("Failed to read config: {0}")]
    ReadError(String),
    #[error("Failed to parse config: {0}")]
    ParseError(String),
}

/// Project configuration from .tidyflow.toml
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectConfig {
    #[serde(default)]
    pub project: ProjectSection,
    #[serde(default)]
    pub setup: SetupSection,
    #[serde(default)]
    pub env: EnvSection,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct ProjectSection {
    pub name: Option<String>,
    pub description: Option<String>,
    #[serde(default = "default_branch")]
    pub default_branch: String,
}

fn default_branch() -> String {
    "main".to_string()
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct SetupSection {
    #[serde(default = "default_timeout")]
    pub timeout: u32,
    pub shell: Option<String>,
    pub working_dir: Option<String>,
    #[serde(default)]
    pub steps: Vec<SetupStep>,
}

fn default_timeout() -> u32 {
    600
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupStep {
    pub name: String,
    pub run: String,
    pub timeout: Option<u32>,
    #[serde(default)]
    pub continue_on_error: bool,
    pub condition: Option<String>,
    #[serde(default)]
    pub env: HashMap<String, String>,
    pub working_dir: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct EnvSection {
    #[serde(default = "default_true")]
    pub inherit: bool,
    #[serde(default)]
    pub vars: HashMap<String, String>,
    #[serde(default)]
    pub path_prepend: PathConfig,
    #[serde(default)]
    pub path_append: PathConfig,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct PathConfig {
    #[serde(default)]
    pub paths: Vec<String>,
}

impl ProjectConfig {
    /// Load config from a project directory
    pub fn load(project_path: &Path) -> Result<Self, ConfigError> {
        let config_path = project_path.join(".tidyflow.toml");
        if !config_path.exists() {
            // Return default config if no config file
            return Ok(Self::default());
        }

        let content = fs::read_to_string(&config_path)
            .map_err(|e| ConfigError::ReadError(e.to_string()))?;

        toml::from_str(&content).map_err(|e| ConfigError::ParseError(e.to_string()))
    }

    /// Get the effective project name
    pub fn effective_name(&self, fallback: &str) -> String {
        self.project.name.clone().unwrap_or_else(|| fallback.to_string())
    }
}

/// Check if a condition is satisfied
pub fn check_condition(condition: &str, working_dir: &Path) -> bool {
    let parts: Vec<&str> = condition.splitn(2, ':').collect();
    if parts.len() != 2 {
        return false;
    }

    let (cond_type, arg) = (parts[0], parts[1]);
    match cond_type {
        "file_exists" => working_dir.join(arg).is_file(),
        "file_not_exists" => !working_dir.join(arg).exists(),
        "dir_exists" => working_dir.join(arg).is_dir(),
        "env_set" => std::env::var(arg).is_ok(),
        "env_not_set" => std::env::var(arg).is_err(),
        "command_exists" => {
            std::process::Command::new("which")
                .arg(arg)
                .output()
                .map(|o| o.status.success())
                .unwrap_or(false)
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_default_config() {
        let config = ProjectConfig::default();
        assert_eq!(config.project.default_branch, "main");
        assert_eq!(config.setup.timeout, 600);
        assert!(config.env.inherit);
    }

    #[test]
    fn test_parse_config() {
        let toml_str = r#"
[project]
name = "test-project"
default_branch = "develop"

[setup]
timeout = 300

[[setup.steps]]
name = "Install deps"
run = "npm install"
condition = "file_exists:package.json"
"#;
        let config: ProjectConfig = toml::from_str(toml_str).unwrap();
        assert_eq!(config.project.name, Some("test-project".to_string()));
        assert_eq!(config.project.default_branch, "develop");
        assert_eq!(config.setup.steps.len(), 1);
        assert_eq!(config.setup.steps[0].name, "Install deps");
    }
}
