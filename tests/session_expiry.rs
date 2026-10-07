//! Integration tests for removing stopped sessions nobody has used for a while.
//!
//! Each test runs real servers against its own throwaway config home. The servers check
//! every second, not every minute, through the debug-only interval override, so a wait
//! that the design gives in minutes is a few seconds here. The two-minute quiet-folder
//! rule has no override, so the one test for it waits in real time.

#![cfg(unix)]

pub mod support;

use std::fs;
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use support::{
    cleanup_test_base, client_handshake, register_runtime_dir, register_spawned_herdr_pid,
    send_detach, unregister_spawned_herdr_pid, wait_for_socket, wait_until, CURRENT_PROTOCOL,
};

/// Seconds between a test server's checks.
const CHECK_SECS: &str = "1";
/// Long enough for a server to run several checks, and to act on a limit it read twice.
const SEVERAL_CHECKS: Duration = Duration::from_secs(8);
/// How long a removal that should happen may take.
const REMOVAL_TIMEOUT: Duration = Duration::from_secs(30);
const POLL: Duration = Duration::from_millis(100);

const HOUR: Duration = Duration::from_secs(3600);
const DAY: Duration = Duration::from_secs(24 * 3600);

const BASE_CONFIG: &str = "onboarding = false\n\n[update]\nversion_check = false\n";
const LIMIT_OFF: &str = "onboarding = false\n\n[update]\nversion_check = false\n\n[session]\nremove_inactive_after_hours = 0\n";
/// Valid TOML with a limit herdr can't read.
const LIMIT_UNREADABLE: &str = "onboarding = false\n\n[update]\nversion_check = false\n\n[session]\nremove_inactive_after_hours = \"never\"\n";
/// No limit line, and a syntax error outside `[session]`.
const CONFIG_BROKEN: &str = "onboarding = false\n[ui\n";

/// A throwaway config home. Dropping it stops its servers and deletes it.
struct Home {
    base: PathBuf,
    /// Seconds between the checks of the servers it starts.
    check_secs: &'static str,
}

struct Server {
    child: Child,
}

impl Drop for Server {
    fn drop(&mut self) {
        let pid = self.child.id();
        let _ = self.child.kill();
        let _ = self.child.wait();
        unregister_spawned_herdr_pid(Some(pid));
    }
}

impl Home {
    fn new(config: &str) -> Self {
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|since| since.as_nanos())
            .unwrap_or(0);
        // Short, so socket paths under it stay below the host's length limit.
        let base = PathBuf::from(format!("/tmp/hsx-{}-{nanos}", std::process::id()));
        let home = Self {
            base,
            check_secs: CHECK_SECS,
        };
        fs::create_dir_all(home.app_dir().join("sessions")).unwrap();
        fs::create_dir_all(home.runtime_dir()).unwrap();
        register_runtime_dir(&home.runtime_dir());
        home.write_config(config);
        home
    }

    fn config_home(&self) -> PathBuf {
        self.base.join("c")
    }

    fn runtime_dir(&self) -> PathBuf {
        self.base.join("runtime")
    }

    fn app_dir(&self) -> PathBuf {
        let name = if cfg!(debug_assertions) {
            "herdr-dev"
        } else {
            "herdr"
        };
        self.config_home().join(name)
    }

    fn session_dir(&self, name: &str) -> PathBuf {
        self.app_dir().join("sessions").join(name)
    }

    fn write_config(&self, config: &str) {
        fs::write(self.app_dir().join("config.toml"), config).unwrap();
    }

    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_herdr"));
        command
            .env("HOME", &self.base)
            .env("XDG_CONFIG_HOME", self.config_home())
            .env("XDG_STATE_HOME", self.base.join("state"))
            .env("XDG_RUNTIME_DIR", self.runtime_dir())
            .env("HERDR_TEST_SESSION_EXPIRY_CHECK_SECS", self.check_secs)
            .env("SHELL", "/bin/sh")
            .env_remove("HERDR_SESSION")
            .env_remove("HERDR_SOCKET_PATH")
            .env_remove("HERDR_CLIENT_SOCKET_PATH")
            .env_remove("HERDR_CONFIG_PATH")
            .env_remove("HERDR_ENV");
        command
    }

    /// Starts a session's server fresh, with no client, and waits until it answers.
    fn start(&self, session: &str) -> Server {
        let child = self
            .command()
            .args(["--session", session, "server"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        register_spawned_herdr_pid(Some(child.id()));
        let server = Server { child };
        wait_for_socket(
            &self.session_dir(session).join("herdr.sock"),
            Duration::from_secs(15),
        );
        server
    }

    /// Connects a client to a running session. It stays attached until dropped.
    fn attach(&self, session: &str) -> UnixStream {
        let socket = self.session_dir(session).join("herdr-client.sock");
        wait_for_socket(&socket, Duration::from_secs(15));
        let mut stream = UnixStream::connect(&socket).unwrap();
        let (_, error) = client_handshake(&mut stream, CURRENT_PROTOCOL, 80, 24).unwrap();
        assert_eq!(error, None);
        stream
    }

    /// The names `herdr session list` shows, in its order.
    fn listed(&self) -> Vec<String> {
        let output = self
            .command()
            .args(["session", "list", "--json"])
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "stderr: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        let list: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        list["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|session| session["name"].as_str().unwrap().to_string())
            .collect()
    }

    /// A stopped session with no stamp files, every file six days old.
    fn old_session(&self, name: &str) -> PathBuf {
        let dir = self.session_dir(name);
        file_at(&dir, "herdr-server.log", days_ago(6));
        file_at(&dir, "session.json", days_ago(6));
        dir
    }
}

impl Drop for Home {
    fn drop(&mut self) {
        cleanup_test_base(&self.base);
    }
}

fn days_ago(days: u32) -> SystemTime {
    SystemTime::now() - days * DAY
}

/// Creates `dir/name`, and `dir` when needed, with the file's time set to `at`.
fn file_at(dir: &Path, name: &str, at: SystemTime) {
    fs::create_dir_all(dir).unwrap();
    let file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join(name))
        .unwrap();
    file.set_modified(at).unwrap();
}

fn modified(path: &Path) -> SystemTime {
    fs::metadata(path).unwrap().modified().unwrap()
}

fn age(path: &Path) -> Duration {
    SystemTime::now()
        .duration_since(modified(path))
        .unwrap_or(Duration::ZERO)
}

/// Waits until the server of `session` has checked at least once after this call.
fn wait_for_a_check(home: &Home, session: &str) {
    let stamp = home.session_dir(session).join("in-use-check");
    let from = SystemTime::now();
    assert!(
        wait_until(Duration::from_secs(15), POLL, || {
            stamp.exists() && modified(&stamp) > from
        }),
        "{session} ran no check"
    );
}

#[test]
fn running_server_removes_old_stopped_sessions() {
    let home = Home::new(BASE_CONFIG);
    let old = home.old_session("old");
    // Only a build that reads `in-use` finds this one due.
    let stale = home.session_dir("stale");
    file_at(&stale, "in-use", days_ago(6));
    file_at(&stale, "in-use-check", days_ago(1));
    file_at(&stale, "herdr-server.log", days_ago(1));
    let fresh = home.session_dir("fresh");
    file_at(&fresh, "in-use", SystemTime::now() - HOUR);
    file_at(&fresh, "in-use-check", SystemTime::now() - HOUR);
    // Old by `in-use`, with no `in-use-check` to vouch for it, as after a rollback. Its
    // newest entry, a day old, is what counts.
    let rolled_back = home.session_dir("rolled-back");
    file_at(&rolled_back, "in-use", days_ago(6));
    file_at(&rolled_back, "herdr-server.log", days_ago(1));

    let _keeper = home.start("keeper");
    let _client = home.attach("keeper");

    assert!(
        wait_until(REMOVAL_TIMEOUT, POLL, || !old.exists() && !stale.exists()),
        "old exists: {}, stale exists: {}",
        old.exists(),
        stale.exists()
    );
    // A few more checks, so every folder has been looked at since those two went.
    thread::sleep(Duration::from_secs(3));
    assert!(fresh.exists());
    assert!(rolled_back.exists());
    assert!(home.session_dir("keeper").exists());
    assert_eq!(home.listed(), ["default", "fresh", "keeper", "rolled-back"]);
}

/// A test config that fails to parse where it was meant to parse turns removal off, and
/// the tests that expect nothing removed would then pass for the wrong reason.
#[test]
fn test_configs_parse_as_meant() {
    for config in [BASE_CONFIG, LIMIT_OFF, LIMIT_UNREADABLE] {
        assert!(config.parse::<toml::Value>().is_ok(), "{config:?}");
    }
    assert!(CONFIG_BROKEN.parse::<toml::Value>().is_err());
}

#[test]
fn limit_zero_removes_nothing() {
    let home = Home::new(LIMIT_OFF);
    let old = home.old_session("old");

    let _keeper = home.start("keeper");
    let _client = home.attach("keeper");
    thread::sleep(SEVERAL_CHECKS);

    wait_for_a_check(&home, "keeper");
    assert!(old.exists());
}

#[test]
fn unreadable_limit_removes_nothing() {
    for config in [LIMIT_UNREADABLE, CONFIG_BROKEN] {
        let home = Home::new(config);
        let old = home.old_session("old");

        let _keeper = home.start("keeper");
        let _client = home.attach("keeper");
        thread::sleep(SEVERAL_CHECKS);

        wait_for_a_check(&home, "keeper");
        assert!(old.exists(), "removed with config {config:?}");
    }
}

#[test]
fn changed_limit_takes_effect_without_restart() {
    let home = Home::new(LIMIT_OFF);
    let mut keeper = home.start("keeper");
    let old = home.old_session("old");

    thread::sleep(SEVERAL_CHECKS);
    wait_for_a_check(&home, "keeper");
    assert!(old.exists());

    home.write_config(BASE_CONFIG);

    assert!(wait_until(REMOVAL_TIMEOUT, POLL, || !old.exists()));
    assert!(keeper.child.try_wait().unwrap().is_none());
}

#[test]
fn quiet_folder_rule_delays_removal() {
    let home = Home::new(BASE_CONFIG);
    let _keeper = home.start("keeper");
    // Past its second check, so the limit has been read twice.
    thread::sleep(SEVERAL_CHECKS);

    let busy = home.session_dir("busy");
    file_at(&busy, "in-use", days_ago(6));
    file_at(&busy, "in-use-check", SystemTime::now());
    file_at(&busy, "herdr-server.log", SystemTime::now());

    thread::sleep(Duration::from_secs(90));
    assert!(busy.exists());
    assert!(wait_until(Duration::from_secs(150), POLL, || !busy.exists()));
}

#[test]
fn shown_session_keeps_its_in_use_file_fresh() {
    let home = Home::new(BASE_CONFIG);
    let _shown = home.start("shown");
    let in_use = home.session_dir("shown").join("in-use");

    let mut client = home.attach("shown");
    thread::sleep(SEVERAL_CHECKS);
    wait_for_a_check(&home, "shown");
    assert!(age(&in_use) < Duration::from_secs(3), "{:?}", age(&in_use));

    // File times can be coarser than the clock, so compare from a second back.
    let detached = SystemTime::now() - Duration::from_secs(1);
    send_detach(&mut client).unwrap();
    drop(client);
    assert!(wait_until(Duration::from_secs(5), POLL, || {
        modified(&in_use) >= detached
    }));
    // A check from just before the detach can satisfy that wait by itself. Give the
    // detach's own touch time to land before reading the time to hold it to.
    thread::sleep(Duration::from_secs(2));
    let at_detach = modified(&in_use);

    thread::sleep(SEVERAL_CHECKS);
    wait_for_a_check(&home, "shown");
    assert_eq!(modified(&in_use), at_detach);
}

#[test]
fn fresh_start_touches_in_use() {
    let mut home = Home::new(BASE_CONFIG);
    // No check runs within the test, so only the touch at the start can stamp the files.
    home.check_secs = "3600";
    let restarted = home.session_dir("restarted");
    file_at(&restarted, "in-use", SystemTime::now() - 73 * HOUR);
    let never_existed = home.session_dir("never-existed");
    assert!(!never_existed.exists());

    let _restarted = home.start("restarted");
    let _never_existed = home.start("never-existed");

    for dir in [&restarted, &never_existed] {
        for stamp in ["in-use", "in-use-check"] {
            let stamp = dir.join(stamp);
            assert!(
                wait_until(Duration::from_secs(5), POLL, || stamp.exists()
                    && age(&stamp) < Duration::from_secs(60)),
                "{}",
                stamp.display()
            );
        }
    }
}
