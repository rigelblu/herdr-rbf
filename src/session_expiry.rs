//! Removes stopped sessions nobody has used for a while.
//!
//! Each named session's server keeps two empty files in its own folder, and only their
//! modification times mean anything. `in-use` is the last moment the session was in use: a
//! client connected, or an agent working or blocked. `in-use-check` is the last moment a
//! server that keeps `in-use` looked, in use or not, so a reader can tell a kept `in-use`
//! from one an older herdr left behind.
//!
//! Once a minute every running server stamps its own files, reads the limit from
//! `config.toml`, and deletes the folder of each stopped session whose last use is past it.
//! Nothing here stops a running session.
//!
//! Every "is it due" decision is a pure function, tested on both sides of each condition:
//! a wrong removal can't be undone.

use std::io;
use std::path::Path;
use std::sync::{Mutex, MutexGuard, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use tracing::{info, warn};

use crate::detect::AgentState;

/// The file whose time is when a session was last in use.
const IN_USE_FILE: &str = "in-use";
/// The file whose time is when a server that keeps [`IN_USE_FILE`] last checked.
const CHECK_FILE: &str = "in-use-check";
/// A session's API socket. Every server binds a new one when it starts or takes over.
const API_SOCKET_FILE: &str = "herdr.sock";

/// How often a server checks.
const CHECK_INTERVAL: Duration = Duration::from_secs(60);
/// Debug builds only: seconds between checks, so tests need not wait whole minutes.
const CHECK_INTERVAL_ENV_VAR: &str = "HERDR_TEST_SESSION_EXPIRY_CHECK_SECS";
/// How much newer than `in-use-check` another entry may be before the stamp stops being
/// trusted. It covers the last check before a server stops, plus its shutdown.
const TRUST_GAP: Duration = Duration::from_secs(180);
/// How long a folder must have gone unchanged before another server may delete it.
const QUIET_FOR: Duration = Duration::from_secs(120);

/// What a server remembers between checks. None of it records when a session was used.
struct Remembered {
    /// When this server was first asked whether a check is due: its start, near enough.
    started: Option<SystemTime>,
    last_check: Option<Instant>,
    first_check_done: bool,
    /// The last failed touch of one of this server's own files, until a check touches
    /// cleanly.
    touch_failure: Option<String>,
    /// That failure has been written to the log. The touch at a fresh start runs before
    /// logging is up, so the check is what reports it.
    touch_failure_logged: bool,
    /// The limit read at the previous check. The outer `None` is "no check yet".
    previous_read: Option<Option<Duration>>,
    removal: Option<tokio::task::JoinHandle<()>>,
}

static REMEMBERED: Mutex<Remembered> = Mutex::new(Remembered {
    started: None,
    last_check: None,
    first_check_done: false,
    touch_failure: None,
    touch_failure_logged: false,
    previous_read: None,
    removal: None,
});

fn remembered() -> MutexGuard<'static, Remembered> {
    REMEMBERED
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// The shortest limit this build acts on, in hours. The installed build never removes
/// faster than an hour, so a mistyped decimal such as `0.72` can't empty the list.
const MIN_HOURS: f64 = if cfg!(debug_assertions) { 0.0 } else { 1.0 };

/// `hours` as a limit, or `None` for off: `0`, a negative, not a number, an infinite
/// value, one too large to hold, one too small to be any time, and one under `min_hours`.
fn limit(hours: f64, min_hours: f64) -> Option<Duration> {
    if hours.is_nan() || hours <= 0.0 || hours < min_hours {
        return None;
    }
    // A positive value can still round to no time at all, which would make everything due.
    Duration::try_from_secs_f64(hours * 3600.0)
        .ok()
        .filter(|limit| !limit.is_zero())
}

/// The limit `config.toml` holds right now, or `None` when removal is off or the file
/// can't be read. An unreadable limit never falls back to the default.
fn read_limit() -> Option<Duration> {
    let loaded = crate::config::load_live_config().ok()?;
    if loaded
        .invalid_sections
        .iter()
        .any(|section| section == "session")
    {
        return None;
    }
    limit(loaded.config.session.remove_inactive_after_hours, MIN_HOURS)
}

/// The limit to act on: this read, only when the previous check read the same limit. One
/// read caught in the middle of a config save must not delete.
fn limit_to_act_on(
    previous_read: Option<Option<Duration>>,
    this_read: Option<Duration>,
) -> Option<Duration> {
    this_read.filter(|limit| previous_read == Some(Some(*limit)))
}

fn check_interval() -> Duration {
    static INTERVAL: OnceLock<Duration> = OnceLock::new();
    *INTERVAL.get_or_init(|| {
        if !cfg!(debug_assertions) {
            return CHECK_INTERVAL;
        }
        std::env::var(CHECK_INTERVAL_ENV_VAR)
            .ok()
            .and_then(|secs| secs.parse::<u64>().ok())
            .filter(|secs| *secs > 0)
            .map_or(CHECK_INTERVAL, Duration::from_secs)
    })
}

/// True once a check interval has passed since the last check. The first check comes one
/// interval after the server starts.
pub(crate) fn check_is_due(now: Instant) -> bool {
    let mut remembered = remembered();
    let Some(last_check) = remembered.last_check else {
        remembered.last_check = Some(now);
        remembered.started = Some(SystemTime::now());
        return false;
    };
    if now.saturating_duration_since(last_check) < check_interval() {
        return false;
    }
    remembered.last_check = Some(now);
    true
}

/// A client is connected, or an agent is working or blocked.
pub(crate) fn is_in_use(clients: usize, mut states: impl Iterator<Item = AgentState>) -> bool {
    clients > 0 || states.any(|state| matches!(state, AgentState::Working | AgentState::Blocked))
}

/// How long after `from` the time `to` is. Zero when `to` is the earlier one.
fn elapsed(from: SystemTime, to: SystemTime) -> Duration {
    to.duration_since(from).unwrap_or(Duration::ZERO)
}

/// Whether a stopped session's `in-use` was kept without a gap: `in-use-check` exists, no
/// other entry is more than [`TRUST_GAP`] newer than it, and the socket, when still there,
/// is not newer than it.
fn stopped_stamp_is_trusted(
    check: Option<SystemTime>,
    newest_other: Option<SystemTime>,
    socket: Option<SystemTime>,
) -> bool {
    let Some(check) = check else {
        return false;
    };
    newest_other.is_none_or(|other| elapsed(check, other) <= TRUST_GAP)
        && socket.is_none_or(|socket| socket <= check)
}

/// Whether a server at its first check can trust the `in-use` it found: `in-use-check` is
/// no more than [`TRUST_GAP`] older than the server's own start.
fn first_check_trusts(check: Option<SystemTime>, server_started: SystemTime) -> bool {
    check.is_some_and(|check| elapsed(check, server_started) <= TRUST_GAP)
}

/// The times of a session folder's own entries. Symlinks are not followed, and an entry
/// that can't be read is left out.
struct FolderTimes {
    in_use: Option<SystemTime>,
    check: Option<SystemTime>,
    socket: Option<SystemTime>,
    /// The newest entry other than the two stamp files.
    newest_other: Option<SystemTime>,
    /// The folder's own time, which stands in when it holds nothing.
    folder: SystemTime,
    /// The folder holds no entry at all, readable or not.
    empty: bool,
}

impl FolderTimes {
    fn read(dir: &Path) -> io::Result<Self> {
        let mut times = Self {
            in_use: None,
            check: None,
            socket: None,
            newest_other: None,
            folder: std::fs::symlink_metadata(dir)?.modified()?,
            empty: true,
        };
        for entry in std::fs::read_dir(dir)? {
            times.empty = false;
            let Ok(entry) = entry else {
                continue;
            };
            let Ok(modified) = entry.metadata().and_then(|metadata| metadata.modified()) else {
                continue;
            };
            let name = entry.file_name();
            if name == IN_USE_FILE {
                times.in_use = Some(modified);
                continue;
            }
            if name == CHECK_FILE {
                times.check = Some(modified);
                continue;
            }
            if name == API_SOCKET_FILE {
                times.socket = Some(modified);
            }
            times.newest_other = times.newest_other.max(Some(modified));
        }
        Ok(times)
    }

    /// The newest entry's time, the stamp files included, or the folder's own when empty.
    fn newest(&self) -> SystemTime {
        self.in_use
            .max(self.check)
            .max(self.newest_other)
            .unwrap_or(self.folder)
    }

    /// When a stopped session was last in use: `in-use`'s time when it can be trusted, else
    /// the newest entry's, else the folder's own time when it holds none.
    fn last_in_use(&self) -> SystemTime {
        match self.in_use {
            Some(in_use)
                if stopped_stamp_is_trusted(self.check, self.newest_other, self.socket) =>
            {
                in_use
            }
            _ => self.newest(),
        }
    }

    /// Past the limit, or empty. An empty folder holds nothing to restore, and it is what
    /// a delete that failed partway leaves behind, so it doesn't wait out a limit.
    fn is_due(&self, now: SystemTime, limit: Duration) -> bool {
        self.empty || session_is_due(self.last_in_use(), now, limit)
    }
}

/// At least `limit` has passed since `last_in_use`. A time in the future counts as no
/// time passed, so a clock moved back can delay a removal and never cause one.
fn session_is_due(last_in_use: SystemTime, now: SystemTime, limit: Duration) -> bool {
    now.duration_since(last_in_use)
        .is_ok_and(|passed| passed >= limit)
}

/// Nothing in the folder changed in the last [`QUIET_FOR`].
fn folder_is_quiet(newest_entry: SystemTime, now: SystemTime) -> bool {
    now.duration_since(newest_entry)
        .is_ok_and(|passed| passed >= QUIET_FOR)
}

fn modified(path: &Path) -> Option<SystemTime> {
    std::fs::symlink_metadata(path)
        .and_then(|metadata| metadata.modified())
        .ok()
}

/// Creates `file` in `dir`, or sets its time to now. Creates `dir` when it isn't there yet.
/// The error names the file.
fn touch(dir: &Path, file: &str) -> Result<(), String> {
    std::fs::create_dir_all(dir)
        .and_then(|()| {
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(dir.join(file))
        })
        .and_then(|opened| opened.set_modified(SystemTime::now()))
        .map_err(|err| format!("{file}: {err}"))
}

/// Touches one of this server's own stamp files and remembers a failure. Does nothing for
/// `default`, whose data folder is the config folder itself.
fn touch_own(file: &str) {
    if crate::session::active_name().is_none() {
        return;
    }
    if let Err(failure) = touch(&crate::session::data_dir(), file) {
        remembered().touch_failure = Some(failure);
    }
}

/// Marks this server's session as in use now.
pub(crate) fn touch_in_use() {
    touch_own(IN_USE_FILE);
}

/// For a server that starts fresh, as the first thing it does: starting a session counts
/// as using it, and no other server can then find its folder due while it starts.
pub(crate) fn touch_at_fresh_start() {
    touch_own(IN_USE_FILE);
    touch_own(CHECK_FILE);
}

/// Deletes the folder of each stopped session last in use at least `limit` ago, other than
/// `own` and `default`. Blocking: it reads folders and probes sockets, so it runs off the
/// server's loop.
fn remove_stopped_sessions(now: SystemTime, limit: Duration, own: Option<String>) {
    let sessions_dir = crate::config::config_dir().join("sessions");
    let entries = match std::fs::read_dir(&sessions_dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == io::ErrorKind::NotFound => return,
        Err(err) => {
            warn!(%err, "could not read the sessions folder");
            return;
        }
    };
    for entry in entries.flatten() {
        // `DirEntry::file_type` doesn't follow a symlink, so nothing outside is reached.
        if !entry.file_type().is_ok_and(|kind| kind.is_dir()) {
            continue;
        }
        let Some(name) = entry.file_name().to_str().map(str::to_string) else {
            continue;
        };
        if name == crate::session::DEFAULT_SESSION_NAME
            || crate::session::validate_name(&name).is_err()
            || own
                .as_deref()
                .is_some_and(|own| own.eq_ignore_ascii_case(&name))
        {
            continue;
        }
        let dir = entry.path();
        // The newest entry is never older than `in-use`, so a session not due by `in-use`
        // is not due at all, and the rest of its folder needn't be read.
        if modified(&dir.join(IN_USE_FILE))
            .is_some_and(|in_use| !session_is_due(in_use, now, limit))
        {
            continue;
        }
        let Ok(times) = FolderTimes::read(&dir) else {
            continue;
        };
        if !times.is_due(now, limit) || !folder_is_quiet(times.newest(), now) {
            continue;
        }
        match crate::session::delete_session(&name) {
            Ok(_) => info!(session = %name, "removed inactive session"),
            Err(err) => warn!(session = %name, %err, "could not remove inactive session"),
        }
    }
}

/// The whole once-a-minute check. Returns true when the server should shut down, which in
/// this version is never.
///
/// Only the server's loop calls this and the touches above, so nothing it remembers changes
/// between its two short locks. The file work in between is done with the lock released.
pub(crate) fn check(in_use: bool, now: SystemTime) -> bool {
    let (started, first_check_done, earlier_failure, failure_logged, previous_read) = {
        let mut remembered = remembered();
        (
            remembered.started,
            remembered.first_check_done,
            remembered.touch_failure.take(),
            remembered.touch_failure_logged,
            remembered.previous_read,
        )
    };

    let own = crate::session::active_name();
    let mut failure = None;
    if own.is_some() {
        let dir = crate::session::data_dir();
        let trusted = first_check_done
            || first_check_trusts(modified(&dir.join(CHECK_FILE)), started.unwrap_or(now));
        if in_use
            || !trusted
            || earlier_failure.is_some()
            || modified(&dir.join(IN_USE_FILE)).is_none()
        {
            failure = touch(&dir, IN_USE_FILE).err();
        }
        failure = failure.or(touch(&dir, CHECK_FILE).err());
    }
    // Once per run of failures, not once a minute.
    let failure_seen = failure.as_ref().or(earlier_failure.as_ref());
    if let (Some(failure), false) = (failure_seen, failure_logged) {
        warn!(%failure, "could not touch a session file; trying again at every check");
    }
    let failure_logged = failure_seen.is_some();
    let this_read = read_limit();

    let mut remembered = remembered();
    remembered.first_check_done = true;
    remembered.touch_failure = failure;
    remembered.touch_failure_logged = failure_logged;
    remembered.previous_read = Some(this_read);
    let Some(limit) = limit_to_act_on(previous_read, this_read) else {
        return false;
    };
    let removal_running = remembered
        .removal
        .as_ref()
        .is_some_and(|removal| !removal.is_finished());
    if !removal_running {
        // Outside a runtime there is no worker to hand the removal to, so it waits.
        if let Ok(runtime) = tokio::runtime::Handle::try_current() {
            remembered.removal =
                Some(runtime.spawn_blocking(move || remove_stopped_sessions(now, limit, own)));
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    const HOUR: Duration = Duration::from_secs(3600);
    const DAY: Duration = Duration::from_secs(24 * 3600);
    const LIMIT: Duration = Duration::from_secs(72 * 3600);

    fn secs(secs: u64) -> Duration {
        Duration::from_secs(secs)
    }

    fn last_in_use(dir: &Path) -> io::Result<SystemTime> {
        FolderTimes::read(dir).map(|times| times.last_in_use())
    }

    /// A throwaway config home with a `sessions/` folder. `XDG_CONFIG_HOME` points at it
    /// for as long as the value lives, and one test at a time holds it.
    struct ConfigHome {
        root: PathBuf,
        _env: MutexGuard<'static, ()>,
    }

    impl ConfigHome {
        fn new() -> Self {
            static ENV: Mutex<()> = Mutex::new(());
            let env = ENV.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            // Short, so a socket path under it stays below the host's length limit.
            let base = if cfg!(unix) {
                PathBuf::from("/tmp")
            } else {
                std::env::temp_dir()
            };
            let nanos = SystemTime::now()
                .duration_since(SystemTime::UNIX_EPOCH)
                .unwrap()
                .as_nanos();
            let root = base.join(format!("hse-{}-{nanos}", std::process::id()));
            std::fs::create_dir_all(root.join(crate::config::app_dir_name()).join("sessions"))
                .unwrap();
            std::env::set_var("XDG_CONFIG_HOME", &root);
            Self { root, _env: env }
        }

        fn sessions(&self) -> PathBuf {
            self.root
                .join(crate::config::app_dir_name())
                .join("sessions")
        }

        fn session(&self, name: &str) -> PathBuf {
            let dir = self.sessions().join(name);
            std::fs::create_dir_all(&dir).unwrap();
            dir
        }

        /// `remove_stopped_sessions`, refused unless the config folder it would delete
        /// from is this throwaway one.
        fn remove_stopped_sessions(&self, now: SystemTime, limit: Duration, own: Option<&str>) {
            let config_dir = crate::config::config_dir();
            assert!(
                config_dir.starts_with(&self.root),
                "{} is outside the test's own {}",
                config_dir.display(),
                self.root.display()
            );
            super::remove_stopped_sessions(now, limit, own.map(str::to_string));
        }
    }

    impl Drop for ConfigHome {
        fn drop(&mut self) {
            std::env::remove_var("XDG_CONFIG_HOME");
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    /// Creates `dir/name` with its time set to `at`.
    fn file_at(dir: &Path, name: &str, at: SystemTime) {
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join(name))
            .unwrap();
        file.set_modified(at).unwrap();
    }

    #[test]
    fn limit_reads_hours_decimals_and_off() {
        assert_eq!(limit(72.0, 0.0), Some(secs(259_200)));
        assert_eq!(limit(0.02, 0.0), Some(secs(72)));
        assert_eq!(limit(0.0, 0.0), None);
        assert_eq!(limit(-1.0, 0.0), None);
        assert_eq!(limit(f64::NAN, 0.0), None);
        assert_eq!(limit(f64::INFINITY, 0.0), None);
        assert_eq!(limit(1e300, 0.0), None);
        assert_eq!(limit(1e-300, 0.0), None);

        assert_eq!(limit(0.5, 1.0), None);
        assert_eq!(limit(1.5, 1.0), Some(secs(5400)));
    }

    #[test]
    fn session_is_due_at_the_limit_and_not_before() {
        let last = SystemTime::UNIX_EPOCH + 1000 * DAY;

        assert!(!session_is_due(last, last + LIMIT - secs(1), LIMIT));
        assert!(session_is_due(last, last + LIMIT, LIMIT));
        // `in-use` later than now: the clock moved back.
        assert!(!session_is_due(last + HOUR, last, LIMIT));
        assert!(!session_is_due(last, last + 1000 * DAY, Duration::MAX));
    }

    #[test]
    fn folder_is_quiet_two_minutes_after_its_last_change() {
        let changed = SystemTime::UNIX_EPOCH + 1000 * DAY;

        assert!(!folder_is_quiet(changed, changed + secs(119)));
        assert!(folder_is_quiet(changed, changed + secs(120)));
        assert!(!folder_is_quiet(changed + HOUR, changed));
    }

    #[test]
    fn is_in_use_counts_clients_working_and_blocked() {
        use AgentState::{Blocked, Idle, Unknown, Working};

        assert!(is_in_use(1, std::iter::empty()));
        assert!(is_in_use(0, [Idle, Working].into_iter()));
        assert!(is_in_use(0, [Blocked].into_iter()));
        assert!(!is_in_use(0, [Idle, Unknown].into_iter()));
        assert!(!is_in_use(0, std::iter::empty()));
    }

    #[test]
    fn limit_is_acted_on_only_when_read_twice() {
        let seventy_two = Some(LIMIT);
        let forty_eight = Some(48 * HOUR);

        assert_eq!(limit_to_act_on(None, seventy_two), None);
        assert_eq!(limit_to_act_on(Some(seventy_two), seventy_two), seventy_two);
        assert_eq!(limit_to_act_on(Some(seventy_two), None), None);
        assert_eq!(limit_to_act_on(Some(None), seventy_two), None);
        assert_eq!(limit_to_act_on(Some(seventy_two), forty_eight), None);
    }

    #[test]
    fn in_use_is_trusted_only_without_a_gap() {
        let home = ConfigHome::new();
        let now = SystemTime::now();
        let in_use = now - 6 * DAY;
        let check = now - DAY;

        // `in-use-check` is the newest entry.
        let newest = home.session("newest");
        file_at(&newest, IN_USE_FILE, in_use);
        file_at(&newest, CHECK_FILE, check);
        file_at(&newest, "herdr-server.log", check - HOUR);
        assert!(stopped_stamp_is_trusted(
            Some(check),
            Some(check - HOUR),
            None
        ));
        assert_eq!(last_in_use(&newest).unwrap(), in_use);

        // Another entry is newer, by less than three minutes.
        let close = home.session("close");
        file_at(&close, IN_USE_FILE, in_use);
        file_at(&close, CHECK_FILE, check);
        file_at(&close, "herdr-server.log", check + secs(170));
        assert!(stopped_stamp_is_trusted(
            Some(check),
            Some(check + secs(170)),
            None
        ));
        assert!(stopped_stamp_is_trusted(
            Some(check),
            Some(check + TRUST_GAP),
            None
        ));
        assert_eq!(last_in_use(&close).unwrap(), in_use);

        // No `in-use-check`.
        let unchecked = home.session("unchecked");
        file_at(&unchecked, IN_USE_FILE, in_use);
        file_at(&unchecked, "herdr-server.log", check);
        assert!(!stopped_stamp_is_trusted(None, Some(check), None));
        assert_eq!(last_in_use(&unchecked).unwrap(), check);

        // A log ten minutes newer.
        let gapped = home.session("gapped");
        file_at(&gapped, IN_USE_FILE, in_use);
        file_at(&gapped, CHECK_FILE, check);
        file_at(&gapped, "herdr-server.log", check + secs(600));
        assert!(!stopped_stamp_is_trusted(
            Some(check),
            Some(check + secs(600)),
            None
        ));
        assert_eq!(last_in_use(&gapped).unwrap(), check + secs(600));

        // A socket one second newer: a server took over and never ran a check.
        let rebound = home.session("rebound");
        file_at(&rebound, IN_USE_FILE, in_use);
        file_at(&rebound, CHECK_FILE, check);
        file_at(&rebound, API_SOCKET_FILE, check + secs(1));
        assert!(!stopped_stamp_is_trusted(
            Some(check),
            Some(check + secs(1)),
            Some(check + secs(1))
        ));
        assert_eq!(last_in_use(&rebound).unwrap(), check + secs(1));
        assert!(stopped_stamp_is_trusted(
            Some(check),
            Some(check),
            Some(check)
        ));

        // A dangling symlink changes none of these.
        #[cfg(unix)]
        {
            let expected = [
                (&newest, in_use),
                (&close, in_use),
                (&unchecked, check),
                (&gapped, check + secs(600)),
                (&rebound, check + secs(1)),
            ];
            for (dir, _) in expected {
                std::os::unix::fs::symlink(dir.join("gone"), dir.join("herdr.sock.agent")).unwrap();
                // Creating the link set its time to now. Put it back among the old files.
                set_link_time(&dir.join("herdr.sock.agent"), in_use);
            }
            for (dir, last) in expected {
                assert_eq!(last_in_use(dir).unwrap(), last, "{}", dir.display());
            }
        }

        // An empty folder is aged by its own time.
        let empty = home.session("empty");
        assert_eq!(
            last_in_use(&empty).unwrap(),
            std::fs::metadata(&empty).unwrap().modified().unwrap()
        );

        let started = now;
        assert!(first_check_trusts(Some(started), started));
        assert!(first_check_trusts(Some(started - secs(60)), started));
        assert!(first_check_trusts(Some(started + secs(5)), started));
        assert!(!first_check_trusts(Some(started - HOUR), started));
        assert!(!first_check_trusts(None, started));
    }

    /// Sets the time of a path that can't be opened as a file: a socket, or a symlink itself.
    #[cfg(unix)]
    fn set_link_time(path: &Path, at: SystemTime) {
        use std::os::unix::ffi::OsStrExt;

        let since_epoch = at.duration_since(SystemTime::UNIX_EPOCH).unwrap();
        let time = libc::timespec {
            tv_sec: since_epoch.as_secs() as libc::time_t,
            tv_nsec: since_epoch.subsec_nanos() as _,
        };
        let path = std::ffi::CString::new(path.as_os_str().as_bytes()).unwrap();
        let result = unsafe {
            libc::utimensat(
                libc::AT_FDCWD,
                path.as_ptr(),
                [time, time].as_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        assert_eq!(result, 0, "{}", io::Error::last_os_error());
    }

    #[test]
    fn removal_takes_only_stopped_sessions_past_the_limit() {
        let home = ConfigHome::new();
        let now = SystemTime::now();

        // No stamp files: aged by its newest file.
        let old = home.session("old");
        file_at(&old, "herdr-server.log", now - 6 * DAY);
        // Trusted, and due only by `in-use`.
        let stale = home.session("stale");
        file_at(&stale, IN_USE_FILE, now - 6 * DAY);
        file_at(&stale, CHECK_FILE, now - DAY);
        file_at(&stale, "herdr-server.log", now - DAY);
        let fresh = home.session("fresh");
        file_at(&fresh, IN_USE_FILE, now - HOUR);
        file_at(&fresh, CHECK_FILE, now - HOUR);
        // Old by `in-use`, but nothing vouches for it: no `in-use-check`, as after a
        // rollback. Its newest entry, a day old, is what counts.
        let rolled_back = home.session("rolled-back");
        file_at(&rolled_back, IN_USE_FILE, now - 6 * DAY);
        file_at(&rolled_back, "herdr-server.log", now - DAY);
        // Past the limit, and changed a minute ago.
        let busy = home.session("busy");
        file_at(&busy, IN_USE_FILE, now - 6 * DAY);
        file_at(&busy, CHECK_FILE, now - secs(60));
        // Past the limit, and this server's own.
        let own = home.session("own");
        file_at(&own, "herdr-server.log", now - 6 * DAY);
        // Not a session: `default` lives in the config folder, and this name isn't valid.
        let default = home.session(crate::session::DEFAULT_SESSION_NAME);
        file_at(&default, "herdr-server.log", now - 6 * DAY);
        let invalid = home.session("not a name");
        file_at(&invalid, "herdr-server.log", now - 6 * DAY);

        home.remove_stopped_sessions(now, LIMIT, Some("own"));

        assert!(!old.exists());
        assert!(!stale.exists());
        assert!(fresh.exists());
        assert!(rolled_back.exists());
        assert!(busy.exists());
        assert!(own.exists());
        assert!(default.exists());
        assert!(invalid.exists());

        // Two minutes after its last change the busy folder goes too.
        home.remove_stopped_sessions(now + secs(60), LIMIT, Some("own"));
        assert!(!busy.exists());
    }

    #[cfg(unix)]
    #[test]
    fn removal_leaves_a_folder_whose_socket_answers() {
        let home = ConfigHome::new();
        let now = SystemTime::now();
        let live = home.session("live");
        let socket = live.join(API_SOCKET_FILE);
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        // Due and quiet, so only the socket guard can save it.
        file_at(&live, IN_USE_FILE, now - 6 * DAY);
        file_at(&live, "herdr-server.log", now - 6 * DAY);
        set_link_time(&socket, now - 6 * DAY);
        assert!(session_is_due(last_in_use(&live).unwrap(), now, LIMIT));

        home.remove_stopped_sessions(now, LIMIT, None);
        assert!(live.exists());

        drop(listener);
        home.remove_stopped_sessions(now, LIMIT, None);
        assert!(!live.exists());
    }

    #[cfg(unix)]
    #[test]
    fn removal_skips_a_folder_it_cannot_delete() {
        use std::os::unix::fs::PermissionsExt;

        let home = ConfigHome::new();
        let now = SystemTime::now();
        let old = home.session("old");
        file_at(&old, "herdr-server.log", now - 6 * DAY);
        let sessions = home.sessions();
        std::fs::set_permissions(&sessions, std::fs::Permissions::from_mode(0o555)).unwrap();

        home.remove_stopped_sessions(now, LIMIT, None);

        let listed = crate::session::list_sessions().unwrap();
        std::fs::set_permissions(&sessions, std::fs::Permissions::from_mode(0o755)).unwrap();
        assert!(listed
            .iter()
            .any(|session| session.name == "old" && !session.running));

        // The failed delete left the folder empty. It is tried again once it is quiet, not
        // a full limit later.
        assert!(std::fs::read_dir(&old).unwrap().next().is_none());
        home.remove_stopped_sessions(now + QUIET_FOR + secs(5), LIMIT, None);
        assert!(!old.exists());
    }

    #[test]
    fn removal_takes_an_empty_folder_once_it_is_quiet() {
        let home = ConfigHome::new();
        let empty = home.session("empty");
        let made = std::fs::metadata(&empty).unwrap().modified().unwrap();

        home.remove_stopped_sessions(made + QUIET_FOR - secs(1), LIMIT, None);
        assert!(empty.exists());

        home.remove_stopped_sessions(made + QUIET_FOR, LIMIT, None);
        assert!(!empty.exists());
    }

    #[cfg(unix)]
    #[test]
    fn removal_never_follows_a_symlink() {
        let home = ConfigHome::new();
        let now = SystemTime::now();
        let elsewhere = home.root.join("elsewhere");
        std::fs::create_dir_all(&elsewhere).unwrap();
        file_at(&elsewhere, "herdr-server.log", now - 6 * DAY);
        let link = home.sessions().join("linked");
        std::os::unix::fs::symlink(&elsewhere, &link).unwrap();

        home.remove_stopped_sessions(now, LIMIT, None);

        assert!(link.symlink_metadata().is_ok());
        assert!(elsewhere.join("herdr-server.log").exists());
    }

    #[test]
    fn read_limit_is_off_for_a_file_it_cannot_read() {
        let home = ConfigHome::new();
        let config = home
            .root
            .join(crate::config::app_dir_name())
            .join("config.toml");
        std::env::remove_var(crate::config::CONFIG_PATH_ENV_VAR);
        let read = |content: &str| {
            std::fs::write(&config, content).unwrap();
            read_limit()
        };

        // A missing file, an empty one and a missing key all give the default.
        assert_eq!(read_limit(), Some(LIMIT));
        assert_eq!(read(""), Some(LIMIT));
        assert_eq!(read("[session]\n"), Some(LIMIT));
        assert_eq!(
            read("[session]\nremove_inactive_after_hours = 48\n"),
            Some(48 * HOUR)
        );
        assert_eq!(
            read("[session]\nremove_inactive_after_hours = 1.5\n"),
            Some(secs(5400))
        );
        assert_eq!(read("[session]\nremove_inactive_after_hours = 0\n"), None);
        assert_eq!(read("[session]\nremove_inactive_after_hours = inf\n"), None);
        assert_eq!(read("[session]\nremove_inactive_after_hours = -3\n"), None);
        // A value herdr can't read, and a file that doesn't parse.
        assert_eq!(
            read("[session]\nremove_inactive_after_hours = \"never\"\n"),
            None
        );
        assert_eq!(read("[ui\nbroken\n"), None);
    }
}
