//! Setup step execution

use crate::workspace::config::{check_condition, ProjectConfig, SetupStep};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::process::{Command, Stdio};
use std::time::Duration;
use tracing::{info, warn};

const MAX_OUTPUT_LEN: usize = 10000;

/// Result of executing all setup steps
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupResult {
    pub success: bool,
    pub steps: Vec<StepResult>,
    pub started_at: DateTime<Utc>,
    pub completed_at: DateTime<Utc>,
}

/// Result of a single setup step
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StepResult {
    pub name: String,
    pub command: String,
    pub success: bool,
    pub exit_code: Option<i32>,
    pub stdout: Option<String>,
    pub stderr: Option<String>,
    pub skipped: bool,
    pub skip_reason: Option<String>,
    pub started_at: DateTime<Utc>,
    pub completed_at: DateTime<Utc>,
}

pub struct SetupExecutor;

impl SetupExecutor {
    /// Execute all setup steps from config
    pub fn execute(config: &ProjectConfig, working_dir: &Path) -> SetupResult {
        let started_at = Utc::now();
        let mut steps = Vec::new();
        let mut all_success = true;

        if config.setup.steps.is_empty() {
            info!("No setup steps defined");
            return SetupResult {
                success: true,
                steps: vec![],
                started_at,
                completed_at: Utc::now(),
            };
        }

        // Prepare environment
        let env = Self::prepare_env(config, working_dir);

        // Get shell
        let shell = config
            .setup
            .shell
            .clone()
            .unwrap_or_else(|| "/bin/sh".to_string());

        for step in &config.setup.steps {
            let result = Self::execute_step(step, working_dir, &shell, &env, config.setup.timeout);

            if !result.success && !result.skipped && !step.continue_on_error {
                all_success = false;
                steps.push(result);
                break;
            }

            if !result.success && !result.skipped {
                all_success = false;
            }

            steps.push(result);
        }

        SetupResult {
            success: all_success,
            steps,
            started_at,
            completed_at: Utc::now(),
        }
    }

    fn prepare_env(config: &ProjectConfig, working_dir: &Path) -> HashMap<String, String> {
        let mut env: HashMap<String, String> = if config.env.inherit {
            std::env::vars().collect()
        } else {
            HashMap::new()
        };

        // Add custom vars
        for (k, v) in &config.env.vars {
            env.insert(k.clone(), v.clone());
        }

        // Modify PATH
        if let Some(path) = env.get("PATH").cloned() {
            let mut paths: Vec<String> = Vec::new();

            // Prepend paths
            for p in &config.env.path_prepend.paths {
                let abs_path = if p.starts_with("./") || p.starts_with("../") {
                    working_dir.join(p).to_string_lossy().to_string()
                } else {
                    p.clone()
                };
                paths.push(abs_path);
            }

            // Original PATH
            paths.push(path);

            // Append paths
            for p in &config.env.path_append.paths {
                let abs_path = if p.starts_with("./") || p.starts_with("../") {
                    working_dir.join(p).to_string_lossy().to_string()
                } else {
                    p.clone()
                };
                paths.push(abs_path);
            }

            env.insert("PATH".to_string(), paths.join(":"));
        }

        env
    }

    fn execute_step(
        step: &SetupStep,
        working_dir: &Path,
        shell: &str,
        base_env: &HashMap<String, String>,
        default_timeout: u32,
    ) -> StepResult {
        let started_at = Utc::now();

        // Check condition
        if let Some(condition) = &step.condition {
            if !check_condition(condition, working_dir) {
                info!(step = step.name, condition = condition, "Step skipped (condition not met)");
                return StepResult {
                    name: step.name.clone(),
                    command: step.run.clone(),
                    success: true,
                    exit_code: None,
                    stdout: None,
                    stderr: None,
                    skipped: true,
                    skip_reason: Some(format!("Condition not met: {}", condition)),
                    started_at,
                    completed_at: Utc::now(),
                };
            }
        }

        // Determine working directory for this step
        let step_working_dir = step
            .working_dir
            .as_ref()
            .map(|d| working_dir.join(d))
            .unwrap_or_else(|| working_dir.to_path_buf());

        // Merge step-specific env
        let mut env = base_env.clone();
        for (k, v) in &step.env {
            env.insert(k.clone(), v.clone());
        }

        info!(step = step.name, command = step.run, "Executing setup step");

        // Execute command
        let _timeout = Duration::from_secs(step.timeout.unwrap_or(default_timeout) as u64);

        let result = Command::new(shell)
            .arg("-c")
            .arg(&step.run)
            .current_dir(&step_working_dir)
            .envs(&env)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .output();

        match result {
            Ok(output) => {
                let exit_code = output.status.code();
                let success = output.status.success();

                let stdout = truncate_output(&String::from_utf8_lossy(&output.stdout));
                let stderr = truncate_output(&String::from_utf8_lossy(&output.stderr));

                if success {
                    info!(step = step.name, exit_code = ?exit_code, "Step completed successfully");
                } else {
                    warn!(step = step.name, exit_code = ?exit_code, stderr = %stderr, "Step failed");
                }

                StepResult {
                    name: step.name.clone(),
                    command: step.run.clone(),
                    success,
                    exit_code,
                    stdout: if stdout.is_empty() { None } else { Some(stdout) },
                    stderr: if stderr.is_empty() { None } else { Some(stderr) },
                    skipped: false,
                    skip_reason: None,
                    started_at,
                    completed_at: Utc::now(),
                }
            }
            Err(e) => {
                warn!(step = step.name, error = %e, "Failed to execute step");
                StepResult {
                    name: step.name.clone(),
                    command: step.run.clone(),
                    success: false,
                    exit_code: None,
                    stdout: None,
                    stderr: Some(e.to_string()),
                    skipped: false,
                    skip_reason: None,
                    started_at,
                    completed_at: Utc::now(),
                }
            }
        }
    }
}

fn truncate_output(s: &str) -> String {
    let s = s.trim();
    if s.len() > MAX_OUTPUT_LEN {
        format!("{}... [truncated]", &s[..MAX_OUTPUT_LEN])
    } else {
        s.to_string()
    }
}
