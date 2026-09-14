//! herdr-rbf `hrdr-4`: the PTY reader re-reads the terminal mode when a waiting ⌘K clear lands.

use super::*;
use std::sync::atomic::{AtomicBool, Ordering};

const FORM_FEED: u8 = 0x0c;

/// A real PTY pair, so the mode set on the child side is what the master reports.
fn open_pty() -> (OwnedFd, OwnedFd) {
    let mut master = -1;
    let mut slave = -1;
    // SAFETY: both out pointers are valid; null name, termios, and winsize ask for defaults.
    let rc = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    assert_eq!(rc, 0, "openpty: {}", std::io::Error::last_os_error());
    // SAFETY: openpty succeeded, so both fds are open and owned by nobody else.
    unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) }
}

fn set_child_canonical(slave: &OwnedFd, canonical: bool) {
    // SAFETY: termios is plain integers and arrays, so all-zero bytes are a valid value.
    let mut attrs: libc::termios = unsafe { std::mem::zeroed() };
    // SAFETY: the fd is an open terminal and `attrs` is valid for reads and writes.
    unsafe {
        assert_eq!(libc::tcgetattr(slave.as_raw_fd(), &mut attrs), 0);
        if canonical {
            attrs.c_lflag |= libc::ICANON;
        } else {
            attrs.c_lflag &= !libc::ICANON;
        }
        attrs.c_lflag &= !libc::ECHO;
        assert_eq!(libc::tcsetattr(slave.as_raw_fd(), libc::TCSANOW, &attrs), 0);
    }
}

/// Read what the program would read until a newline arrives, failing after a second of silence.
fn read_child_input_line(slave: &OwnedFd) -> Vec<u8> {
    let mut line = Vec::new();
    while !line.ends_with(b"\n") {
        let mut poll = libc::pollfd {
            fd: slave.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: `poll` is one valid pollfd.
        let ready = unsafe { libc::poll(&mut poll, 1, 1000) };
        assert!(ready > 0, "child input so far: {line:?}");
        let mut buf = [0u8; 16];
        // SAFETY: `buf` is valid for `buf.len()` writes.
        let n = unsafe { libc::read(slave.as_raw_fd(), buf.as_mut_ptr().cast(), buf.len()) };
        assert!(n > 0, "read: {}", std::io::Error::last_os_error());
        line.extend_from_slice(&buf[..n as usize]);
    }
    line
}

/// Spawn an actor on the master whose first read reports a landed cooked-mode clear, make the
/// program print once, then send a newline so the program's next input line is readable.
fn child_input_after_a_landed_clear(canonical: bool) -> Vec<u8> {
    let (master, slave) = open_pty();
    set_child_canonical(&slave, canonical);
    let armed = Arc::new(AtomicBool::new(true));
    let (read_tx, read_rx) = std_mpsc::channel();
    let handle = PtyIoActor::spawn(PtyIoActorConfig {
        pane_id: 1,
        master_fd: master,
        initially_quiesced: false,
        on_read: Box::new(move |_| {
            let _ = read_tx.send(());
            PtyReadResult {
                terminal_responses: Vec::new(),
                ctrl_l_if_raw_mode: armed.swap(false, Ordering::AcqRel),
            }
        }),
        on_reader_exit: None,
    })
    .expect("actor spawn");

    // SAFETY: the slave fd is open and the buffer is one valid byte.
    let wrote = unsafe { libc::write(slave.as_raw_fd(), b"x".as_ptr().cast(), 1) };
    assert_eq!(wrote, 1);
    read_rx
        .recv_timeout(Duration::from_secs(1))
        .expect("actor read the program's output");
    handle
        .try_write_user_input(Bytes::from_static(b"\n"))
        .expect("queue newline");
    read_child_input_line(&slave)
}

#[test]
fn master_reports_the_child_side_input_mode() {
    let (master, slave) = open_pty();

    set_child_canonical(&slave, false);
    assert_eq!(
        crate::platform::tty_fd_input_canonical(master.as_raw_fd()),
        Some(false)
    );
    set_child_canonical(&slave, true);
    assert_eq!(
        crate::platform::tty_fd_input_canonical(master.as_raw_fd()),
        Some(true)
    );
}

#[test]
fn key_press_mode_read_round_trips_through_the_actor() {
    let (master, slave) = open_pty();
    let handle = PtyIoActor::spawn(PtyIoActorConfig {
        pane_id: 1,
        master_fd: master,
        initially_quiesced: false,
        on_read: Box::new(|_| PtyReadResult::empty()),
        on_reader_exit: None,
    })
    .expect("actor spawn");

    set_child_canonical(&slave, false);
    assert_eq!(handle.input_canonical_mode(), Some(false));
    set_child_canonical(&slave, true);
    assert_eq!(handle.input_canonical_mode(), Some(true));
}

#[test]
fn landed_clear_sends_ctrl_l_when_the_program_is_raw_by_then() {
    assert_eq!(
        child_input_after_a_landed_clear(false),
        vec![FORM_FEED, b'\n']
    );
}

#[test]
fn landed_clear_sends_nothing_while_the_program_stays_cooked() {
    assert_eq!(child_input_after_a_landed_clear(true), b"\n");
}
