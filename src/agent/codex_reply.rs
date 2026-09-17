use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::{Mutex, OnceLock};
use std::time::Duration;

const TAIL_BYTES: u64 = 4 * 1024 * 1024;
pub(crate) const SESSION_LOOKUP_BUDGET: Duration = Duration::from_millis(150);
const MIN_SESSION_ID_LEN: usize = 8;

#[derive(Clone)]
struct CachedMessages {
    length: u64,
    messages: Vec<String>,
}

fn cache() -> &'static Mutex<std::collections::HashMap<std::path::PathBuf, CachedMessages>> {
    static CACHE: OnceLock<Mutex<std::collections::HashMap<std::path::PathBuf, CachedMessages>>> =
        OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

fn session_path_cache(
) -> &'static Mutex<std::collections::HashMap<(std::path::PathBuf, String), std::path::PathBuf>> {
    static CACHE: OnceLock<
        Mutex<std::collections::HashMap<(std::path::PathBuf, String), std::path::PathBuf>>,
    > = OnceLock::new();
    CACHE.get_or_init(|| Mutex::new(std::collections::HashMap::new()))
}

pub(crate) fn recent_messages(session_id: &str, budget: Duration) -> Option<Vec<String>> {
    if !valid_session_id(session_id) {
        return None;
    }
    let session_id = session_id.to_owned();
    read_with_budget(budget, move || read_session(&session_id))
}

fn read_with_budget<T, F>(budget: Duration, read: F) -> Option<T>
where
    T: Send + 'static,
    F: FnOnce() -> Option<T> + Send + 'static,
{
    if budget.is_zero() {
        return None;
    }
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    std::thread::spawn(move || {
        let _ = sender.send(read());
    });
    receiver.recv_timeout(budget).ok().flatten()
}

fn valid_session_id(session_id: &str) -> bool {
    session_id.len() >= MIN_SESSION_ID_LEN
        && session_id.len() <= 512
        && session_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

fn read_session(session_id: &str) -> Option<Vec<String>> {
    let path = find_session_path(session_id)?;
    let length = std::fs::metadata(&path).ok()?.len();
    if let Some(messages) = cache()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&path)
        .filter(|entry| entry.length == length)
        .map(|entry| entry.messages.clone())
    {
        return Some(messages);
    }
    let messages = read_recent_messages(&path)?;
    cache()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .insert(
            path,
            CachedMessages {
                length,
                messages: messages.clone(),
            },
        );
    Some(messages)
}

fn find_session_path(session_id: &str) -> Option<std::path::PathBuf> {
    let root = codex_home()?.join("sessions");
    let cache_key = (root.clone(), session_id.to_owned());
    if let Some(path) = session_path_cache()
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .get(&cache_key)
        .filter(|path| path.is_file())
        .cloned()
    {
        return Some(path);
    }
    let suffix = format!("-{session_id}.jsonl");
    let mut pending = vec![(root, 0usize)];
    while let Some((directory, depth)) = pending.pop() {
        for entry in std::fs::read_dir(directory).ok()?.flatten() {
            let path = entry.path();
            let file_type = entry.file_type().ok()?;
            if file_type.is_dir() && depth < 3 {
                pending.push((path, depth + 1));
            } else if file_type.is_file()
                && path.extension().and_then(std::ffi::OsStr::to_str) == Some("jsonl")
                && path
                    .file_name()
                    .and_then(std::ffi::OsStr::to_str)
                    .is_some_and(|name| name.ends_with(&suffix))
            {
                session_path_cache()
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .insert(cache_key, path.clone());
                return Some(path);
            }
        }
    }
    None
}

fn codex_home() -> Option<std::path::PathBuf> {
    if let Some(path) = std::env::var_os("CODEX_HOME").filter(|value| !value.is_empty()) {
        return Some(std::path::PathBuf::from(path));
    }
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .filter(|value| !value.is_empty())
        .map(std::path::PathBuf::from)
        .map(|path| path.join(".codex"))
}

pub(crate) fn read_recent_messages(path: &Path) -> Option<Vec<String>> {
    let mut file = std::fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let start = length.saturating_sub(TAIL_BYTES);
    file.seek(SeekFrom::Start(start)).ok()?;
    let snapshot_length = length - start;
    let mut bytes = Vec::with_capacity(snapshot_length as usize);
    file.take(snapshot_length).read_to_end(&mut bytes).ok()?;
    if bytes.len() != snapshot_length as usize {
        return None;
    }
    if !bytes.is_empty() && !bytes.ends_with(b"\n") {
        return None;
    }
    if start > 0 {
        let first_newline = bytes.iter().position(|byte| *byte == b'\n')?;
        bytes.drain(..=first_newline);
    }
    let tail = std::str::from_utf8(&bytes).ok()?;
    let mut messages = Vec::new();
    for line in tail.lines().filter(|line| !line.is_empty()) {
        let record: serde_json::Value = serde_json::from_str(line).ok()?;
        if record.get("type").and_then(serde_json::Value::as_str) != Some("response_item") {
            continue;
        }
        let payload = record.get("payload")?;
        if payload.get("type").and_then(serde_json::Value::as_str) != Some("message")
            || payload.get("role").and_then(serde_json::Value::as_str) != Some("assistant")
        {
            continue;
        }
        let content = payload.get("content")?.as_array()?;
        let text = content
            .iter()
            .filter_map(|item| item.get("text").and_then(serde_json::Value::as_str))
            .collect::<String>();
        if !text.is_empty() {
            messages.push(text);
        }
    }
    Some(messages)
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicU64, Ordering};

    fn temp_home(label: &str) -> std::path::PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        std::env::temp_dir().join(format!(
            "herdr-codex-reply-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn timeout_budget_returns_none() {
        // The reader outlasts the budget by 60x. `recv_timeout` returns early when a value
        // already arrived, so a narrow margin passes whenever the suite deschedules this
        // thread between the spawn and the wait — observed at 1ms against a 25ms reader.
        let result = super::read_with_budget(std::time::Duration::from_millis(50), || {
            std::thread::sleep(std::time::Duration::from_secs(3));
            Some(())
        });

        assert_eq!(result, None);
    }

    #[test]
    fn session_path_requires_plausible_exact_id() {
        let _guard = crate::config::test_config_env_lock().lock().unwrap();
        let home = temp_home("session-path");
        let sessions = home.join("sessions/2026/09/17");
        std::fs::create_dir_all(&sessions).expect("create sessions tree");
        std::fs::write(
            sessions.join("rollout-test-target-session-extra.jsonl"),
            b"",
        )
        .expect("write suffix decoy");
        let previous = std::env::var_os("CODEX_HOME");
        std::env::set_var("CODEX_HOME", &home);

        let substring_match = super::find_session_path("target-session");
        let single_character_is_valid = super::valid_session_id("x");
        let exact = sessions.join("rollout-test-target-session.jsonl");
        std::fs::write(&exact, b"").expect("write exact session path");
        let exact_match = super::find_session_path("target-session");
        let cache_key = (home.join("sessions"), "target-session".to_owned());
        let cached_match = super::session_path_cache()
            .lock()
            .unwrap()
            .get(&cache_key)
            .cloned();

        if let Some(value) = previous {
            std::env::set_var("CODEX_HOME", value);
        } else {
            std::env::remove_var("CODEX_HOME");
        }
        std::fs::remove_dir_all(home).expect("remove sessions tree");

        assert_eq!(substring_match, None);
        assert!(!single_character_is_valid);
        assert_eq!(exact_match, Some(exact.clone()));
        assert_eq!(cached_match, Some(exact));
    }
}
