//! Secure API key storage — Keychain on macOS; 0600 file under data dir elsewhere.
//! Never writes keys into SQLite.

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

pub fn key_path(data_dir: &Path) -> PathBuf {
    data_dir.join("secrets").join("gemini_api_key")
}

fn store_gemini_key_file(data_dir: &Path, key: &str) -> Result<(), String> {
    let path = key_path(data_dir);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let mut f = fs::File::create(&path).map_err(|e| e.to_string())?;
    f.write_all(key.as_bytes()).map_err(|e| e.to_string())?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn store_gemini_key(data_dir: &Path, key: &str) -> Result<(), String> {
    let key = key.trim();
    if key.is_empty() {
        return Err("empty key".into());
    }
    #[cfg(target_os = "macos")]
    {
        // Prefer Keychain; require -w (stdin-only prompts are non-TTY and can exit 0
        // without a retrievable secret). Verify round-trip before skipping the file fallback.
        use std::process::Command;
        let status = Command::new("security")
            .args([
                "add-generic-password",
                "-a",
                "adhd-companion",
                "-s",
                "com.adhdcompanion.app.gemini",
                "-w",
                key,
                "-U",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
        if let Ok(s) = status {
            if s.success() {
                if load_gemini_key_from_keychain().as_deref() == Some(key) {
                    // Drop any stale file copy so Keychain remains the sole source.
                    let path = key_path(data_dir);
                    let _ = fs::remove_file(path);
                    return Ok(());
                }
            }
        }
        // Stale/unreadable Keychain entries must not shadow the file fallback.
        let _ = Command::new("security")
            .args([
                "delete-generic-password",
                "-a",
                "adhd-companion",
                "-s",
                "com.adhdcompanion.app.gemini",
            ])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status();
    }
    store_gemini_key_file(data_dir, key)
}

#[cfg(target_os = "macos")]
fn load_gemini_key_from_keychain() -> Option<String> {
    let out = std::process::Command::new("security")
        .args([
            "find-generic-password",
            "-a",
            "adhd-companion",
            "-s",
            "com.adhdcompanion.app.gemini",
            "-w",
        ])
        .output()
        .ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() {
        None
    } else {
        Some(s)
    }
}

pub fn load_gemini_key(data_dir: &Path) -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        if let Some(s) = load_gemini_key_from_keychain() {
            return Some(s);
        }
    }
    let path = key_path(data_dir);
    fs::read_to_string(path)
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
}

pub fn clear_gemini_key(data_dir: &Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("security")
            .args([
                "delete-generic-password",
                "-a",
                "adhd-companion",
                "-s",
                "com.adhdcompanion.app.gemini",
            ])
            .status();
    }
    let path = key_path(data_dir);
    if path.exists() {
        fs::remove_file(path).map_err(|e| e.to_string())?;
    }
    Ok(())
}

pub fn key_fingerprint(key: &str) -> String {
    let mut h = Sha256::new();
    h.update(key.as_bytes());
    hex::encode(h.finalize())[..12].to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn roundtrip_file_store() {
        let dir = tempdir().unwrap();
        store_gemini_key(dir.path(), "test-key-abc").unwrap();
        assert_eq!(load_gemini_key(dir.path()).as_deref(), Some("test-key-abc"));
        clear_gemini_key(dir.path()).unwrap();
        assert!(load_gemini_key(dir.path()).is_none());
    }
}
