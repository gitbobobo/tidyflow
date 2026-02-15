use crate::server::file_api;
use std::path::Path;

const MAX_FILE_SIZE: u64 = 1024 * 1024;

/// 格式化文件引用，将文件内容附加到消息中
pub fn format_file_refs(files: &[String], workspace_root: &Path) -> Result<String, String> {
    let mut content = String::new();

    for file in files {
        let path = workspace_root.join(file);

        match std::fs::metadata(&path) {
            Ok(metadata) => {
                if metadata.len() > MAX_FILE_SIZE {
                    return Err(format!(
                        "文件 '{}' 大小超过 1MB 限制 ({} bytes)",
                        file,
                        metadata.len()
                    ));
                }
            }
            Err(e) => return Err(format!("无法读取文件 '{}' 元数据: {}", file, e)),
        }

        let (file_content, _) = file_api::read_file(workspace_root, file)
            .map_err(|e| format!("读取文件 '{}' 失败: {}", file, e))?;

        content.push_str(&format!("\n\n=== File: {} ===\n{}", file, file_content));
    }

    Ok(content)
}

pub fn append_file_refs_to_message(
    message: &str,
    file_refs: &Option<Vec<String>>,
    workspace_root: &Path,
) -> Result<String, String> {
    if let Some(files) = file_refs {
        if !files.is_empty() {
            let file_content = format_file_refs(files, workspace_root)?;
            return Ok(format!("{}{}", file_content, message));
        }
    }

    Ok(message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_format_file_refs() {
        // 创建临时文件
        let mut temp_file = NamedTempFile::new().unwrap();
        writeln!(temp_file, "Hello, World!").unwrap();

        let path = temp_file.path().parent().unwrap();
        let file_name = temp_file.path().file_name().unwrap().to_str().unwrap();

        let files = vec![file_name.to_string()];
        let result = format_file_refs(&files, path).unwrap();

        assert!(result.contains("=== File:"));
        assert!(result.contains("Hello, World!"));
    }

    #[test]
    fn test_append_file_refs_to_message() {
        let mut temp_file = NamedTempFile::new().unwrap();
        writeln!(temp_file, "File content").unwrap();

        let path = temp_file.path().parent().unwrap();
        let file_name = temp_file.path().file_name().unwrap().to_str().unwrap();

        let message = "Please analyze this file";
        let file_refs = Some(vec![file_name.to_string()]);

        let result = append_file_refs_to_message(message, &file_refs, path).unwrap();

        assert!(result.contains("=== File:"));
        assert!(result.contains("File content"));
        assert!(result.contains(message));
    }

    #[test]
    fn test_empty_file_refs() {
        let path = Path::new("/tmp");
        let message = "Hello";
        let file_refs: Option<Vec<String>> = None;

        let result = append_file_refs_to_message(message, &file_refs, path).unwrap();
        assert_eq!(result, "Hello");
    }
}
