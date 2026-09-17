//! Integration tests for terminal attach title propagation and handoff restore.

#![cfg(unix)]

pub mod support;

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::thread;
use std::time::{Duration, Instant};

use portable_pty::{native_pty_system, Child, CommandBuilder, MasterPty, PtySize};
use support::{
    cleanup_test_base, register_runtime_dir, register_spawned_herdr_pid,
    unregister_spawned_herdr_pid, wait_for_socket, wait_until,
};

type SharedOutput = std::sync::Arc<Mutex<String>>;

fn unique_test_dir() -> PathBuf {
    static COUNTER: AtomicUsize = AtomicUsize::new(0);
    let n = COUNTER.fetch_add(1, Ordering::Relaxed);
    PathBuf::from(format!("/tmp/hatt-{}-{n}", std::process::id()))
}

struct SpawnedHerdr {
    _master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
}

impl Drop for SpawnedHerdr {
    fn drop(&mut self) {
        let pid = self.child.process_id();
        let _ = self.child.kill();
        unregister_spawned_herdr_pid(pid);
    }
}

struct SpawnedAttach {
    _master: Box<dyn MasterPty + Send>,
    child: Box<dyn Child + Send + Sync>,
    output: SharedOutput,
}

impl Drop for SpawnedAttach {
    fn drop(&mut self) {
        let pid = self.child.process_id();
        let _ = self.child.kill();
        unregister_spawned_herdr_pid(pid);
    }
}

fn test_lock() -> MutexGuard<'static, ()> {
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    LOCK.get_or_init(|| Mutex::new(()))
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn spawn_server_with_config(
    config_home: &Path,
    runtime_dir: &Path,
    api_socket_path: &Path,
    config: &str,
) -> SpawnedHerdr {
    let config_path = config_home.join("herdr").join("config.toml");
    fs::create_dir_all(config_path.parent().unwrap()).unwrap();
    let dev_config_path = config_home.join("herdr-dev").join("config.toml");
    fs::create_dir_all(dev_config_path.parent().unwrap()).unwrap();
    fs::create_dir_all(runtime_dir).unwrap();
    register_runtime_dir(runtime_dir);
    fs::write(&config_path, config).unwrap();
    fs::write(&dev_config_path, config).unwrap();

    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();

    let mut cmd = CommandBuilder::new(env!("CARGO_BIN_EXE_herdr"));
    cmd.arg("server");
    cmd.env("XDG_CONFIG_HOME", config_home);
    cmd.env("XDG_RUNTIME_DIR", runtime_dir);
    cmd.env("HERDR_CONFIG_PATH", &config_path);
    cmd.env("HERDR_SOCKET_PATH", api_socket_path);
    cmd.env_remove("HERDR_CLIENT_SOCKET_PATH");
    cmd.env_remove("HERDR_SESSION");
    cmd.env_remove("HERDR_ENV");
    cmd.env("SHELL", "/bin/sh");

    let child = pair.slave.spawn_command(cmd).unwrap();
    register_spawned_herdr_pid(child.process_id());
    drop(pair.slave);

    SpawnedHerdr {
        _master: pair.master,
        child,
    }
}

fn spawn_attach_client(
    config_home: &Path,
    runtime_dir: &Path,
    api_socket: &Path,
    terminal_id: &str,
) -> SpawnedAttach {
    let pair = native_pty_system()
        .openpty(PtySize {
            rows: 24,
            cols: 80,
            pixel_width: 0,
            pixel_height: 0,
        })
        .unwrap();

    let mut cmd = CommandBuilder::new(env!("CARGO_BIN_EXE_herdr"));
    cmd.arg("terminal");
    cmd.arg("attach");
    cmd.arg(terminal_id);
    cmd.env("XDG_CONFIG_HOME", config_home);
    cmd.env("XDG_RUNTIME_DIR", runtime_dir);
    cmd.env("HERDR_SOCKET_PATH", api_socket);
    cmd.env_remove("HERDR_CLIENT_SOCKET_PATH");
    cmd.env_remove("HERDR_SESSION");
    cmd.env_remove("HERDR_ENV");
    cmd.env("SHELL", "/bin/sh");

    let child = pair.slave.spawn_command(cmd).unwrap();
    register_spawned_herdr_pid(child.process_id());
    drop(pair.slave);

    let output = spawn_pty_drain(pair.master.try_clone_reader().unwrap());

    SpawnedAttach {
        _master: pair.master,
        child,
        output,
    }
}

struct RequestError {
    retryable: bool,
    message: String,
}

fn try_request(
    socket_path: &Path,
    request: serde_json::Value,
) -> Result<serde_json::Value, RequestError> {
    let mut stream = UnixStream::connect(socket_path).map_err(|err| RequestError {
        retryable: true,
        message: format!("connect {}: {err}", socket_path.display()),
    })?;
    let request_text = request.to_string();
    stream
        .write_all(request_text.as_bytes())
        .map_err(|err| RequestError {
            retryable: true,
            message: format!("write request to {}: {err}", socket_path.display()),
        })?;
    stream.write_all(b"\n").map_err(|err| RequestError {
        retryable: true,
        message: format!("write newline to {}: {err}", socket_path.display()),
    })?;
    stream.flush().map_err(|err| RequestError {
        retryable: true,
        message: format!("flush request to {}: {err}", socket_path.display()),
    })?;
    let mut line = String::new();
    BufReader::new(stream)
        .read_line(&mut line)
        .map_err(|err| RequestError {
            retryable: true,
            message: format!("read response from {}: {err}", socket_path.display()),
        })?;
    if line.is_empty() {
        return Err(RequestError {
            retryable: true,
            message: format!(
                "empty response from {} for request {request_text}",
                socket_path.display()
            ),
        });
    }
    serde_json::from_str(&line).map_err(|err| RequestError {
        retryable: false,
        message: format!(
            "parse response from {} for request {request_text}: {err}; response was {line:?}",
            socket_path.display()
        ),
    })
}

fn request(socket_path: &Path, request: serde_json::Value) -> serde_json::Value {
    try_request(socket_path, request).unwrap_or_else(|err| panic!("{}", err.message))
}

fn assert_ok(response: &serde_json::Value) {
    assert!(
        response.get("result").is_some(),
        "api request failed: {response}"
    );
}

fn wait_for_api(socket_path: &Path, timeout: Duration) {
    let deadline = Instant::now() + timeout;
    let mut last_error = String::new();
    while Instant::now() < deadline {
        match try_request(
            socket_path,
            serde_json::json!({"id":"test:ping","method":"ping","params":{}}),
        ) {
            Ok(response) if response.get("result").is_some() => return,
            Ok(response) => panic!("api ping returned non-success response: {response}"),
            Err(err) if !err.retryable => panic!("{}", err.message),
            Err(err) => {
                last_error = err.message;
            }
        }
        thread::sleep(Duration::from_millis(25));
    }
    panic!(
        "api did not become ready at {}; last error: {last_error}",
        socket_path.display()
    );
}

fn spawn_pty_drain(mut reader: Box<dyn Read + Send>) -> SharedOutput {
    let output: SharedOutput = std::sync::Arc::new(Mutex::new(String::new()));
    let thread_output = output.clone();
    thread::spawn(move || {
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) => break,
                Ok(n) => thread_output
                    .lock()
                    .unwrap_or_else(|p| p.into_inner())
                    .push_str(&String::from_utf8_lossy(&buf[..n])),
                Err(_) => break,
            }
        }
    });
    output
}

fn read_output(output: &SharedOutput) -> String {
    output.lock().unwrap_or_else(|p| p.into_inner()).clone()
}

#[cfg(target_os = "linux")]
fn wait_for_replacement_server_pid(runtime_dir: &Path, old_pid: u32, timeout: Duration) -> u32 {
    let deadline = Instant::now() + timeout;
    let mut last_pids = Vec::new();
    while Instant::now() < deadline {
        last_pids = support::herdr_server_pids_for_runtime_dir(runtime_dir).unwrap_or_default();
        if let Some(pid) = last_pids.iter().copied().find(|pid| *pid != old_pid) {
            return pid;
        }
        thread::sleep(Duration::from_millis(25));
    }
    panic!(
        "replacement server for {} did not appear; last pids: {:?}",
        runtime_dir.display(),
        last_pids
    );
}

#[cfg(target_os = "macos")]
fn wait_for_replacement_server_pid(_runtime_dir: &Path, old_pid: u32, timeout: Duration) -> u32 {
    let handoff_socket_pattern = format!("herdr-handoff-{old_pid}.sock");
    let deadline = Instant::now() + timeout;
    let mut last_stdout = String::new();
    while Instant::now() < deadline {
        if let Ok(output) = std::process::Command::new("pgrep")
            .args(["-af", &handoff_socket_pattern])
            .output()
        {
            last_stdout = String::from_utf8_lossy(&output.stdout).into_owned();
            for line in last_stdout.lines() {
                let Some(pid_text) = line.split_whitespace().next() else {
                    continue;
                };
                let Ok(pid) = pid_text.parse::<u32>() else {
                    continue;
                };
                if pid != old_pid {
                    return pid;
                }
            }
        }
        thread::sleep(Duration::from_millis(25));
    }
    panic!(
        "replacement server for {} did not appear; last pgrep output: {}",
        _runtime_dir.display(),
        last_stdout
    );
}

#[test]
fn real_attach_client_writes_the_title() {
    let _lock = test_lock();
    let base = unique_test_dir();
    let config_home = base.join("cfg");
    let runtime_dir = base.join("rt");
    let api_socket = runtime_dir.join("h.sock");

    let config = "onboarding = false\n\n[terminal]\ndefault_shell = \"/bin/sh\"\n";
    let spawned = spawn_server_with_config(&config_home, &runtime_dir, &api_socket, config);
    wait_for_socket(&api_socket, Duration::from_secs(10));
    wait_for_api(&api_socket, Duration::from_secs(10));

    let created = request(
        &api_socket,
        serde_json::json!({
            "id": "create_ws",
            "method": "workspace.create",
            "params": {"cwd": "/tmp", "focus": true}
        }),
    );
    assert_ok(&created);
    let pane_id = created["result"]["root_pane"]["pane_id"]
        .as_str()
        .expect("pane_id")
        .to_string();
    let terminal_id = created["result"]["root_pane"]["terminal_id"]
        .as_str()
        .expect("terminal_id")
        .to_string();

    let attach = spawn_attach_client(&config_home, &runtime_dir, &api_socket, &terminal_id);

    // Step 1: while the pane has no title, output contains no `\x1b]0;` at all (never `herdr`)
    assert!(
        wait_until(Duration::from_secs(10), Duration::from_millis(50), || {
            !read_output(&attach.output).is_empty()
        }),
        "attach client produced no output within timeout"
    );
    let pane_info = request(
        &api_socket,
        serde_json::json!({
            "id": "get_untitled",
            "method": "pane.get",
            "params": { "pane_id": pane_id.clone() }
        }),
    );
    assert_ok(&pane_info);
    let term_title = pane_info["result"]["pane"].get("terminal_title");
    assert!(
        term_title.is_none() || term_title == Some(&serde_json::Value::Null),
        "expected no terminal_title in pane.get, got: {term_title:?}"
    );

    thread::sleep(Duration::from_millis(500));
    let initial_out = read_output(&attach.output);
    assert!(
        !initial_out.contains("\x1b]0;"),
        "attach output must not contain title sequence while untitled: {initial_out:?}"
    );

    // Step 2: print first title, then second title
    let send1 = request(
        &api_socket,
        serde_json::json!({
            "id": "send1",
            "method": "pane.send_input",
            "params": {
                "pane_id": pane_id,
                "text": "printf '\\033]0;✳ probe\\007'",
                "keys": ["Enter"]
            }
        }),
    );
    assert_ok(&send1);

    assert!(
        wait_until(Duration::from_secs(10), Duration::from_millis(50), || {
            read_output(&attach.output).contains("\x1b]0;✳ probe\x07")
        }),
        "first title did not appear in attach output: {:?}",
        read_output(&attach.output)
    );

    let send2 = request(
        &api_socket,
        serde_json::json!({
            "id": "send2",
            "method": "pane.send_input",
            "params": {
                "pane_id": pane_id,
                "text": "printf '\\033]0;◐ probe 2\\007'",
                "keys": ["Enter"]
            }
        }),
    );
    assert_ok(&send2);

    assert!(
        wait_until(Duration::from_secs(10), Duration::from_millis(50), || {
            read_output(&attach.output).contains("\x1b]0;◐ probe 2\x07")
        }),
        "second title did not appear in attach output: {:?}",
        read_output(&attach.output)
    );

    drop(attach);
    let _ = request(
        &api_socket,
        serde_json::json!({"id":"stop","method":"server.stop","params":{}}),
    );
    drop(spawned);
    cleanup_test_base(&base);
}

#[test]
fn empty_window_title_setting_keeps_the_attach_client_untitled() {
    let _lock = test_lock();
    let base = unique_test_dir();
    let config_home = base.join("cfg");
    let runtime_dir = base.join("rt");
    let api_socket = runtime_dir.join("h.sock");

    let config =
        "onboarding = false\n\n[terminal]\ndefault_shell = \"/bin/sh\"\n\n[ui]\nwindow_title = \"\"\n";
    let spawned = spawn_server_with_config(&config_home, &runtime_dir, &api_socket, config);
    wait_for_socket(&api_socket, Duration::from_secs(10));
    wait_for_api(&api_socket, Duration::from_secs(10));

    let created = request(
        &api_socket,
        serde_json::json!({
            "id": "create_ws",
            "method": "workspace.create",
            "params": {"cwd": "/tmp", "focus": true}
        }),
    );
    assert_ok(&created);
    let pane_id = created["result"]["root_pane"]["pane_id"]
        .as_str()
        .expect("pane_id")
        .to_string();
    let terminal_id = created["result"]["root_pane"]["terminal_id"]
        .as_str()
        .expect("terminal_id")
        .to_string();

    let attach = spawn_attach_client(&config_home, &runtime_dir, &api_socket, &terminal_id);

    let send = request(
        &api_socket,
        serde_json::json!({
            "id": "send",
            "method": "pane.send_input",
            "params": {
                "pane_id": pane_id,
                "text": "printf '\\033]0;✳ probe\\007'",
                "keys": ["Enter"]
            }
        }),
    );
    assert_ok(&send);

    assert!(
        wait_until(Duration::from_secs(10), Duration::from_millis(50), || {
            let res = request(
                &api_socket,
                serde_json::json!({
                    "id": "get_title",
                    "method": "pane.get",
                    "params": { "pane_id": pane_id.clone() }
                }),
            );
            res["result"]["pane"]["terminal_title"].as_str() == Some("✳ probe")
        }),
        "pane did not record terminal_title '✳ probe'"
    );

    thread::sleep(Duration::from_millis(500));
    let out = read_output(&attach.output);
    assert!(
        !out.contains("\x1b]0;"),
        "an empty window_title must keep attach output free of title sequences: {out:?}"
    );

    drop(attach);
    let _ = request(
        &api_socket,
        serde_json::json!({"id":"stop","method":"server.stop","params":{}}),
    );
    drop(spawned);
    cleanup_test_base(&base);
}

#[test]
fn titles_survive_a_live_handoff() {
    let _lock = test_lock();
    let base = unique_test_dir();
    let config_home = base.join("cfg");
    let runtime_dir = base.join("rt");
    let api_socket = runtime_dir.join("h.sock");

    let config = "onboarding = false\n\n[terminal]\ndefault_shell = \"/bin/sh\"\n";
    let spawned = spawn_server_with_config(&config_home, &runtime_dir, &api_socket, config);
    wait_for_socket(&api_socket, Duration::from_secs(10));
    wait_for_api(&api_socket, Duration::from_secs(10));

    let created = request(
        &api_socket,
        serde_json::json!({
            "id": "create_ws",
            "method": "workspace.create",
            "params": {"cwd": "/tmp", "focus": true}
        }),
    );
    assert_ok(&created);
    let pane_id = created["result"]["root_pane"]["pane_id"]
        .as_str()
        .expect("pane_id")
        .to_string();

    // Run: printf '\033]0;✳ probe title\007'; sleep 30
    let send = request(
        &api_socket,
        serde_json::json!({
            "id": "send",
            "method": "pane.send_input",
            "params": {
                "pane_id": pane_id,
                "text": "printf '\\033]0;✳ probe title\\007'; sleep 30",
                "keys": ["Enter"]
            }
        }),
    );
    assert_ok(&send);

    // Wait until pane.get reports terminal_title == "✳ probe title"
    assert!(wait_until(
        Duration::from_secs(10),
        Duration::from_millis(50),
        || {
            let res = request(
                &api_socket,
                serde_json::json!({
                    "id": "get_before",
                    "method": "pane.get",
                    "params": { "pane_id": pane_id.clone() }
                }),
            );
            res["result"]["pane"]["terminal_title"].as_str() == Some("✳ probe title")
        }
    ));

    // Perform live handoff
    let server_pid = spawned.child.process_id().expect("server pid");
    assert_ok(&request(
        &api_socket,
        serde_json::json!({"id":"handoff","method":"server.live_handoff","params":{}}),
    ));

    let replacement_pid =
        wait_for_replacement_server_pid(&runtime_dir, server_pid, Duration::from_secs(10));
    register_spawned_herdr_pid(Some(replacement_pid));
    wait_for_api(&api_socket, Duration::from_secs(10));

    // Before the pane writes anything new, pane.get reports terminal_title: "✳ probe title"
    let get_after = request(
        &api_socket,
        serde_json::json!({
            "id": "get_after",
            "method": "pane.get",
            "params": { "pane_id": pane_id }
        }),
    );
    assert_ok(&get_after);
    assert_eq!(
        get_after["result"]["pane"]["terminal_title"].as_str(),
        Some("✳ probe title")
    );

    let restored_terminal_id = get_after["result"]["pane"]["terminal_id"]
        .as_str()
        .expect("restored terminal_id");
    let attach = spawn_attach_client(
        &config_home,
        &runtime_dir,
        &api_socket,
        restored_terminal_id,
    );
    assert!(
        wait_until(Duration::from_secs(10), Duration::from_millis(50), || {
            read_output(&attach.output).contains("\x1b]0;✳ probe title\x07")
        }),
        "expected restored title in attach output after handoff: {:?}",
        read_output(&attach.output)
    );

    drop(attach);
    let _ = request(
        &api_socket,
        serde_json::json!({"id":"stop","method":"server.stop","params":{}}),
    );
    drop(spawned);
    cleanup_test_base(&base);
}
