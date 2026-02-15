use std::path::PathBuf;
use tidyflow_core::OpenCodeManager;

#[tokio::test]
async fn test_manager_creation() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    assert!(manager.get_port() >= 49152);
    assert!(manager.get_base_url().starts_with("http://127.0.0.1:"));
}

#[tokio::test]
async fn test_is_running_initially_false() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    assert!(!manager.is_running().await);
}

#[tokio::test]
async fn test_stop_server_when_not_running() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    let result = manager.stop_server().await;
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_health_check_fails_for_unavailable_server() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    let result = manager.check_health().await;
    assert!(result.is_err());
}

#[tokio::test]
async fn test_multiple_managers_get_different_ports() {
    let manager1 = OpenCodeManager::new(PathBuf::from("/tmp"));
    let manager2 = OpenCodeManager::new(PathBuf::from("/tmp"));
    assert_ne!(manager1.get_port(), manager2.get_port());
}

#[tokio::test]
async fn test_base_url_consistency() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    let port = manager.get_port();
    let expected_url = format!("http://127.0.0.1:{}", port);
    assert_eq!(manager.get_base_url(), expected_url);
}
