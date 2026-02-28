use url::Url;

pub fn normalize_directory_with_file_url(directory: &str) -> String {
    let trimmed = directory.trim();
    if trimmed.is_empty() {
        return String::new();
    }

    let as_path = if let Ok(url) = Url::parse(trimmed) {
        if url.scheme().eq_ignore_ascii_case("file") {
            url.to_file_path()
                .ok()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| trimmed.to_string())
        } else {
            trimmed.to_string()
        }
    } else {
        trimmed.to_string()
    };

    as_path.trim_end_matches('/').to_string()
}

pub fn normalize_directory(directory: &str) -> String {
    directory.trim_end_matches('/').to_string()
}
