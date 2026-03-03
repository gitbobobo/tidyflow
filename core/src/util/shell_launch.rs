pub(crate) const LOGIN_ZSH_PATH: &str = "/bin/zsh";
const LOGIN_ZSH_EXEC_SNIPPET: &str = "exec \"$@\"";
const LOGIN_ZSH_ARG0: &str = "tidyflow-zsh";

/// 构造通过登录态 zsh 启动目标命令的参数：
/// /bin/zsh -l -c 'exec "$@"' tidyflow-zsh <program> <args...>
pub(crate) fn build_login_zsh_exec_args(
    program: &str,
    program_args: &[String],
) -> Result<Vec<String>, String> {
    let trimmed = program.trim();
    if trimmed.is_empty() {
        return Err("program must not be empty".to_string());
    }

    let mut args = vec![
        "-l".to_string(),
        "-c".to_string(),
        LOGIN_ZSH_EXEC_SNIPPET.to_string(),
        LOGIN_ZSH_ARG0.to_string(),
        trimmed.to_string(),
    ];
    args.extend(program_args.iter().cloned());
    Ok(args)
}

/// 将命令数组包装为登录态 zsh 启动参数。
/// 输入格式：["program", "arg1", "arg2", ...]
pub(crate) fn wrap_command_for_login_zsh(
    command_and_args: &[String],
) -> Result<Vec<String>, String> {
    let Some(program) = command_and_args.first() else {
        return Err("command must not be empty".to_string());
    };
    build_login_zsh_exec_args(program, &command_and_args[1..])
}

#[cfg(test)]
mod tests {
    use super::{build_login_zsh_exec_args, wrap_command_for_login_zsh};

    #[test]
    fn build_login_zsh_exec_args_should_wrap_program_and_args() {
        let result = build_login_zsh_exec_args("codex", &["app-server".to_string()])
            .expect("build args should succeed");
        assert_eq!(
            result,
            vec![
                "-l".to_string(),
                "-c".to_string(),
                "exec \"$@\"".to_string(),
                "tidyflow-zsh".to_string(),
                "codex".to_string(),
                "app-server".to_string(),
            ]
        );
    }

    #[test]
    fn build_login_zsh_exec_args_should_preserve_special_characters() {
        let special = vec![
            "--flag".to_string(),
            "space value".to_string(),
            "quote\"value".to_string(),
            "dollar$value".to_string(),
            "semi;colon".to_string(),
        ];
        let result =
            build_login_zsh_exec_args("copilot", &special).expect("build args should succeed");
        assert_eq!(result[5..], special);
    }

    #[test]
    fn build_login_zsh_exec_args_should_reject_empty_program() {
        let err = build_login_zsh_exec_args("   ", &[]).expect_err("empty program should fail");
        assert!(err.contains("program"));
    }

    #[test]
    fn wrap_command_for_login_zsh_should_reject_empty_command() {
        let err = wrap_command_for_login_zsh(&[]).expect_err("empty command should fail");
        assert!(err.contains("empty"));
    }
}
