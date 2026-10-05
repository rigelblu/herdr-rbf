use super::*;

/// Runs the thin client and enters the main event loop.
pub fn run_client() -> io::Result<()> {
    run_client_with_mode(None, None, "connecting to server")
}

#[cfg(unix)]
pub fn run_terminal_attach(terminal_id: String, takeover: bool) -> io::Result<()> {
    let result = run_client_with_mode(
        Some((terminal_id, takeover)),
        Some(AttachEscapeState::default()),
        "attaching to terminal",
    );
    // A refused or ended attach prints like a shutdown after connect, not as a debug dump;
    // any other error keeps its usual path
    if let Err(err) = &result {
        if let Some(attach_err) = err
            .get_ref()
            .and_then(|e| e.downcast_ref::<TerminalAttachError>())
        {
            let report = crate::exit_report::attach_error_layout(attach_err);
            eprintln!("{}", crate::exit_report::attach_ending(report, attach_err));
            std::process::exit(1);
        }
    }
    result
}

#[cfg(windows)]
pub fn run_terminal_attach(_terminal_id: String, _takeover: bool) -> io::Result<()> {
    debug_assert!(!crate::platform::capabilities().direct_terminal_attach);
    Err(io::Error::new(
        io::ErrorKind::Unsupported,
        "direct terminal attach is not supported on Windows yet",
    ))
}
