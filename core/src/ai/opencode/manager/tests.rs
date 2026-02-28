
use super::*;

#[test]
fn test_ephemeral_port_allocation() {
    let port = OpenCodeManager::allocate_ephemeral_port();
    assert!(port >= 49152, "Port should be in ephemeral range");
}

#[test]
fn test_base_url_format() {
    let manager = OpenCodeManager::new(PathBuf::from("/tmp"));
    assert_eq!(
        manager.get_base_url(),
        format!("http://127.0.0.1:{}", manager.get_port())
    );
}
