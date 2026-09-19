use std::io;

use interprocess::local_socket::traits::Stream as _;

use crate::api::schema;
use crate::ipc::LocalStream;
use crate::protocol::{self, ClientMessage, ServerMessage};

const REQUEST_ID: &str = "terminal-attach:startup";

#[derive(Clone, Copy)]
pub(super) struct AttachGeometry {
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) cell_width_px: u32,
    pub(super) cell_height_px: u32,
    pub(super) exact_cell_size: bool,
    pub(super) mouse_capture: bool,
}

pub(super) fn prepare_connection(
    mut stream: LocalStream,
    mut handshake: super::handshake::HandshakeResult,
    terminal_id: String,
    takeover: bool,
    socket_path: &std::path::Path,
    geometry: AttachGeometry,
) -> io::Result<(LocalStream, super::handshake::HandshakeResult, bool)> {
    let supports_semantic_attach = handshake
        .endpoint_methods
        .as_ref()
        .is_some_and(|methods| methods.iter().any(|method| method == "terminal.attach"));
    if supports_semantic_attach {
        handshake.prefetched_messages = prepare(&mut stream, terminal_id, takeover)?;
        return Ok((stream, handshake, true));
    }

    drop(stream);
    let mut direct_stream = crate::ipc::connect_local_stream(socket_path)
        .map_err(|error| io::Error::other(error.to_string()))?;
    handshake = super::do_handshake(
        &mut direct_stream,
        geometry.cols,
        geometry.rows,
        geometry.cell_width_px,
        geometry.cell_height_px,
        geometry.exact_cell_size,
        None,
        false,
        geometry.mouse_capture,
        true,
    )
    .map_err(|error| io::Error::other(error.to_string()))?;
    super::write_to_server(
        &mut direct_stream,
        &ClientMessage::AttachTerminal {
            terminal_id,
            takeover,
        },
    )?;
    Ok((direct_stream, handshake, false))
}

pub(super) fn prepare(
    stream: &mut LocalStream,
    terminal_id: String,
    takeover: bool,
) -> io::Result<Vec<ServerMessage>> {
    prepare_with_timeout(
        stream,
        terminal_id,
        takeover,
        super::handshake::handshake_read_timeout(),
    )
}

fn prepare_with_timeout(
    stream: &mut LocalStream,
    terminal_id: String,
    takeover: bool,
    timeout: std::time::Duration,
) -> io::Result<Vec<ServerMessage>> {
    let deadline = std::time::Instant::now()
        .checked_add(timeout)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "invalid attach timeout"))?;
    let result = prepare_inner_until(stream, terminal_id, takeover, Some(deadline));
    let clear_result = stream.set_recv_timeout(None);
    match (result, clear_result) {
        (Ok(messages), Ok(())) => Ok(messages),
        (Err(error), _) | (_, Err(error)) => Err(error),
    }
}

#[cfg(test)]
fn prepare_inner(
    stream: &mut LocalStream,
    terminal_id: String,
    takeover: bool,
) -> io::Result<Vec<ServerMessage>> {
    prepare_inner_until(stream, terminal_id, takeover, None)
}

fn prepare_inner_until(
    stream: &mut LocalStream,
    terminal_id: String,
    takeover: bool,
    deadline: Option<std::time::Instant>,
) -> io::Result<Vec<ServerMessage>> {
    let mut prefetched = Vec::new();
    let mut pending_projection = Vec::new();
    let mut request_sent = false;
    let mut response_bytes = Vec::new();
    let mut attached_revision = None;
    let mut matching_snapshot = false;
    let mut matching_surface = false;

    loop {
        if let Some(deadline) = deadline {
            let remaining = deadline
                .checked_duration_since(std::time::Instant::now())
                .ok_or_else(|| {
                    io::Error::new(io::ErrorKind::TimedOut, "semantic attach timed out")
                })?;
            stream.set_recv_timeout(Some(remaining.max(std::time::Duration::from_millis(1))))?;
        }
        let message: ServerMessage =
            protocol::read_message(stream, protocol::MAX_GRAPHICS_FRAME_SIZE)
                .map_err(|error| io::Error::other(error.to_string()))?;
        match &message {
            ServerMessage::EndpointControl { kind, data }
                if kind == crate::protocol::endpoint::ENDPOINT_SNAPSHOT_KIND =>
            {
                let snapshot: protocol::ClientShellSnapshot = serde_json::from_str(data)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                if !request_sent {
                    let request = schema::Request {
                        id: REQUEST_ID.into(),
                        method: schema::Method::TerminalAttach(schema::TerminalAttachParams {
                            terminal_id: terminal_id.clone(),
                            takeover,
                        }),
                    };
                    super::write_to_server(
                        stream,
                        &ClientMessage::ClientShellEndpointRequest {
                            boot_id: snapshot.boot_id.clone(),
                            request: serde_json::to_string(&request).map_err(|error| {
                                io::Error::new(io::ErrorKind::InvalidData, error)
                            })?,
                        },
                    )?;
                    request_sent = true;
                }
                if attached_revision == Some(snapshot.revision) {
                    matching_snapshot = true;
                    prefetched.push(message);
                } else if attached_revision.is_none() {
                    pending_projection.push(message);
                }
            }
            ServerMessage::PaneSurface(surface) => {
                if attached_revision == Some(surface.projection_revision) {
                    matching_surface = true;
                    prefetched.push(message);
                } else if attached_revision.is_none() {
                    pending_projection.push(message);
                }
            }
            ServerMessage::ClientShellEndpointResponseChunk {
                request_id,
                final_chunk,
                data,
                ..
            } if request_id == REQUEST_ID => {
                response_bytes.extend_from_slice(data);
                if *final_chunk {
                    if let Ok(error) =
                        serde_json::from_slice::<schema::ErrorResponse>(&response_bytes)
                    {
                        return Err(io::Error::other(error.error.message));
                    }
                    let response =
                        serde_json::from_slice::<schema::SuccessResponse>(&response_bytes)
                            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                    let schema::ResponseResult::TerminalAttached {
                        projection_revision,
                        ..
                    } = response.result
                    else {
                        return Err(io::Error::new(
                            io::ErrorKind::InvalidData,
                            "terminal.attach returned an unexpected result",
                        ));
                    };
                    attached_revision = Some(projection_revision);
                    for pending in pending_projection.drain(..) {
                        match &pending {
                            ServerMessage::EndpointControl { kind, data }
                                if kind == crate::protocol::endpoint::ENDPOINT_SNAPSHOT_KIND
                                    && serde_json::from_str::<protocol::ClientShellSnapshot>(
                                        data,
                                    )
                                    .is_ok_and(|snapshot| {
                                        snapshot.revision == projection_revision
                                    }) =>
                            {
                                matching_snapshot = true;
                                prefetched.push(pending);
                            }
                            ServerMessage::PaneSurface(surface)
                                if surface.projection_revision == projection_revision =>
                            {
                                matching_surface = true;
                                prefetched.push(pending);
                            }
                            _ => {}
                        }
                    }
                }
            }
            // A semantic connection briefly starts as a workspace shell. Ignore
            // that transient presentation's title; the attached terminal title,
            // when present, follows the successful attach response.
            ServerMessage::WindowTitle { .. } if attached_revision.is_none() => {}
            ServerMessage::ServerShutdown { reason } => {
                return Err(io::Error::other(
                    reason.clone().unwrap_or_else(|| "server shut down".into()),
                ));
            }
            _ => prefetched.push(message),
        }
        if attached_revision.is_some() && matching_snapshot && matching_surface {
            return Ok(prefetched);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use interprocess::local_socket::traits::Listener as _;

    static NEXT_SOCKET_ID: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

    fn local_socket_path() -> std::path::PathBuf {
        std::env::temp_dir().join(format!(
            "herdr-semantic-attach-{}-{}-{}.sock",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time")
                .as_nanos(),
            NEXT_SOCKET_ID.fetch_add(1, std::sync::atomic::Ordering::Relaxed),
        ))
    }

    fn local_stream_pair() -> (LocalStream, LocalStream, std::path::PathBuf) {
        let path = local_socket_path();
        let _ = std::fs::remove_file(&path);
        let listener = crate::ipc::bind_local_listener(&path).expect("bind local listener");
        let client = crate::ipc::connect_local_stream(&path).expect("connect local stream");
        let server = listener.accept().expect("accept local stream");
        drop(listener);
        (client, server, path)
    }

    fn snapshot(revision: u64) -> ServerMessage {
        let mut snapshot: protocol::ClientShellSnapshot = serde_json::from_str(include_str!(
            "../../tests/fixtures/endpoint-snapshot-v1.json"
        ))
        .expect("snapshot fixture");
        snapshot.boot_id = "boot".into();
        snapshot.revision = revision;
        ServerMessage::EndpointControl {
            kind: protocol::endpoint::ENDPOINT_SNAPSHOT_KIND.into(),
            data: serde_json::to_string(&snapshot).expect("serialize snapshot"),
        }
    }

    fn surface(revision: u64) -> ServerMessage {
        ServerMessage::PaneSurface(protocol::PaneSurfaceFrame {
            boot_id: "boot".into(),
            projection_revision: revision,
            surface_revision: 1,
            frame: protocol::FrameData {
                cells: Vec::new(),
                width: 0,
                height: 0,
                cursor: None,
                hyperlinks: Vec::new(),
                graphics: Vec::new(),
            },
            panes: Vec::new(),
            splits: Vec::new(),
            popup: None,
            graphics: protocol::SurfaceGraphicsScene::default(),
        })
    }

    fn read_attach_request(server: &mut LocalStream) {
        let request: ClientMessage = protocol::read_message(server, protocol::MAX_FRAME_SIZE)
            .expect("terminal attach request");
        assert!(matches!(
            request,
            ClientMessage::ClientShellEndpointRequest { request, .. }
                if serde_json::from_str::<schema::Request>(&request).is_ok_and(|request| {
                    matches!(request.method, schema::Method::TerminalAttach(_))
                })
        ));
    }

    #[test]
    fn startup_reconnects_with_direct_attach_when_semantic_attach_is_not_advertised() {
        let path = local_socket_path();
        let _ = std::fs::remove_file(&path);
        let listener = crate::ipc::bind_local_listener(&path).expect("bind local listener");
        let mut client = crate::ipc::connect_local_stream(&path).expect("connect local stream");
        let fake_server = std::thread::spawn(move || {
            let mut endpoint = listener.accept().expect("accept endpoint stream");
            let hello: ClientMessage =
                protocol::read_message(&mut endpoint, protocol::MAX_FRAME_SIZE)
                    .expect("endpoint hello");
            assert!(matches!(
                hello,
                ClientMessage::EndpointControl { ref kind, .. }
                    if kind == protocol::endpoint::ENDPOINT_HELLO_KIND
            ));
            let welcome = protocol::endpoint::EndpointServerWelcome::compatible(Vec::new());
            protocol::write_message(
                &mut endpoint,
                &ServerMessage::EndpointControl {
                    kind: protocol::endpoint::ENDPOINT_WELCOME_KIND.into(),
                    data: serde_json::to_string(&welcome).expect("serialize endpoint welcome"),
                },
            )
            .expect("endpoint welcome");

            let mut direct = listener.accept().expect("accept direct stream");
            drop(endpoint);
            let hello: ClientMessage =
                protocol::read_message(&mut direct, protocol::MAX_FRAME_SIZE)
                    .expect("terminal hello");
            assert!(matches!(
                hello,
                ClientMessage::TerminalHello {
                    cols: 91,
                    rows: 37,
                    ..
                }
            ));
            protocol::write_message(
                &mut direct,
                &ServerMessage::Welcome {
                    version: protocol::PROTOCOL_VERSION,
                    encoding: protocol::RenderEncoding::TerminalAnsi,
                    error: None,
                },
            )
            .expect("terminal welcome");
            let attach: ClientMessage =
                protocol::read_message(&mut direct, protocol::MAX_FRAME_SIZE)
                    .expect("direct attach request");
            assert_eq!(
                attach,
                ClientMessage::AttachTerminal {
                    terminal_id: "term_legacy".into(),
                    takeover: true,
                }
            );
        });

        let handshake = super::super::do_handshake(
            &mut client,
            91,
            37,
            8,
            16,
            true,
            Some(protocol::ClientSurfaceSize { cols: 91, rows: 37 }),
            true,
            false,
            true,
        )
        .expect("endpoint handshake");
        let (_stream, handshake, semantic) = prepare_connection(
            client,
            handshake,
            "term_legacy".into(),
            true,
            &path,
            AttachGeometry {
                cols: 91,
                rows: 37,
                cell_width_px: 8,
                cell_height_px: 16,
                exact_cell_size: true,
                mouse_capture: false,
            },
        )
        .expect("legacy direct attach fallback");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
        assert!(!semantic);
        assert_eq!(handshake.encoding, protocol::RenderEncoding::TerminalAnsi);
        assert!(handshake.endpoint_methods.is_none());
    }

    #[test]
    fn startup_keeps_exact_projection_evidence_across_later_stale_messages() {
        let (mut client, mut server, path) = local_stream_pair();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            let response = schema::SuccessResponse {
                id: REQUEST_ID.into(),
                result: schema::ResponseResult::TerminalAttached {
                    pane_id: "pane".into(),
                    projection_revision: 7,
                },
            };
            for message in [
                ServerMessage::WindowTitle {
                    title: Some("workspace title".into()),
                },
                ServerMessage::ClientShellEndpointResponseChunk {
                    boot_id: "boot".into(),
                    request_id: REQUEST_ID.into(),
                    final_chunk: true,
                    data: serde_json::to_vec(&response).expect("serialize response"),
                },
                ServerMessage::WindowTitle {
                    title: Some("terminal title".into()),
                },
                snapshot(7),
                snapshot(6),
                surface(7),
            ] {
                protocol::write_message(&mut server, &message).expect("startup message");
            }
        });

        let messages = prepare_inner(&mut client, "term_1".into(), false)
            .expect("attached projection should become ready");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
        assert!(messages.iter().any(|message| matches!(
            message,
            ServerMessage::EndpointControl { kind, data }
                if kind == protocol::endpoint::ENDPOINT_SNAPSHOT_KIND
                    && serde_json::from_str::<protocol::ClientShellSnapshot>(data)
                        .is_ok_and(|snapshot| snapshot.revision == 7)
        )));
        assert!(messages.iter().any(|message| {
            matches!(message, ServerMessage::PaneSurface(surface)
                if surface.projection_revision == 7)
        }));
        assert!(!messages.iter().any(|message| matches!(
            message,
            ServerMessage::EndpointControl { kind, data }
                if kind == protocol::endpoint::ENDPOINT_SNAPSHOT_KIND
                    && serde_json::from_str::<protocol::ClientShellSnapshot>(data)
                        .is_ok_and(|snapshot| snapshot.revision != 7)
        )));
        assert!(!messages.iter().any(|message| matches!(
            message,
            ServerMessage::WindowTitle { title: Some(title) } if title == "workspace title"
        )));
        assert!(messages.iter().any(|message| matches!(
            message,
            ServerMessage::WindowTitle { title: Some(title) } if title == "terminal title"
        )));
    }

    #[test]
    fn startup_keeps_exact_projection_evidence_that_arrives_before_the_response() {
        let (mut client, mut server, path) = local_stream_pair();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            let response = schema::SuccessResponse {
                id: REQUEST_ID.into(),
                result: schema::ResponseResult::TerminalAttached {
                    pane_id: "pane".into(),
                    projection_revision: 7,
                },
            };
            for message in [
                snapshot(7),
                snapshot(6),
                surface(7),
                surface(6),
                ServerMessage::ClientShellEndpointResponseChunk {
                    boot_id: "boot".into(),
                    request_id: REQUEST_ID.into(),
                    final_chunk: true,
                    data: serde_json::to_vec(&response).expect("serialize response"),
                },
            ] {
                protocol::write_message(&mut server, &message).expect("startup message");
            }
        });

        let messages = prepare_inner(&mut client, "term_1".into(), false)
            .expect("early exact projection should become ready");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
        assert!(messages.iter().any(|message| matches!(
            message,
            ServerMessage::EndpointControl { kind, data }
                if kind == protocol::endpoint::ENDPOINT_SNAPSHOT_KIND
                    && serde_json::from_str::<protocol::ClientShellSnapshot>(data)
                        .is_ok_and(|snapshot| snapshot.revision == 7)
        )));
        assert!(messages.iter().any(|message| {
            matches!(message, ServerMessage::PaneSurface(surface)
                if surface.projection_revision == 7)
        }));
        assert!(!messages.iter().any(|message| matches!(
            message,
            ServerMessage::EndpointControl { kind, data }
                if kind == protocol::endpoint::ENDPOINT_SNAPSHOT_KIND
                    && serde_json::from_str::<protocol::ClientShellSnapshot>(data)
                        .is_ok_and(|snapshot| snapshot.revision != 7)
        )));
        assert!(!messages.iter().any(|message| {
            matches!(message, ServerMessage::PaneSurface(surface)
                if surface.projection_revision != 7)
        }));
    }

    #[test]
    fn startup_returns_an_advertised_attach_rejection_without_a_projection() {
        let (mut client, mut server, path) = local_stream_pair();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            let response = schema::ErrorResponse {
                id: REQUEST_ID.into(),
                error: schema::ErrorBody {
                    code: "terminal_attach_failed".into(),
                    message: "terminal is already attached".into(),
                },
            };
            protocol::write_message(
                &mut server,
                &ServerMessage::ClientShellEndpointResponseChunk {
                    boot_id: "boot".into(),
                    request_id: REQUEST_ID.into(),
                    final_chunk: true,
                    data: serde_json::to_vec(&response).expect("serialize response"),
                },
            )
            .expect("attach rejection");
        });

        let error = prepare_inner(&mut client, "term_1".into(), false)
            .expect_err("an advertised attach rejection must stop startup");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
        assert_eq!(error.to_string(), "terminal is already attached");
    }

    #[test]
    fn startup_rejects_a_disconnected_incoherent_first_projection() {
        let (mut client, mut server, path) = local_stream_pair();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            let response = schema::SuccessResponse {
                id: REQUEST_ID.into(),
                result: schema::ResponseResult::TerminalAttached {
                    pane_id: "pane".into(),
                    projection_revision: 7,
                },
            };
            for message in [
                ServerMessage::ClientShellEndpointResponseChunk {
                    boot_id: "boot".into(),
                    request_id: REQUEST_ID.into(),
                    final_chunk: true,
                    data: serde_json::to_vec(&response).expect("serialize response"),
                },
                snapshot(6),
                surface(6),
            ] {
                protocol::write_message(&mut server, &message).expect("startup message");
            }
        });

        prepare_inner(&mut client, "term_1".into(), false)
            .expect_err("startup must not accept a mismatched projection before disconnect");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn startup_times_out_when_the_attach_response_never_arrives() {
        let (mut client, mut server, path) = local_stream_pair();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            let _ = release_rx.recv_timeout(std::time::Duration::from_secs(2));
        });

        let started = std::time::Instant::now();
        prepare_with_timeout(
            &mut client,
            "term_1".into(),
            false,
            std::time::Duration::from_millis(20),
        )
        .expect_err("silent semantic attach must time out");
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        release_tx.send(()).expect("release fake server");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn startup_deadline_expires_while_the_server_keeps_sending_stale_messages() {
        let (mut client, mut server, path) = local_stream_pair();
        let (release_tx, release_rx) = std::sync::mpsc::channel();
        let fake_server = std::thread::spawn(move || {
            protocol::write_message(&mut server, &snapshot(1)).expect("initial snapshot");
            read_attach_request(&mut server);
            while release_rx.try_recv().is_err() {
                if protocol::write_message(&mut server, &snapshot(2)).is_err() {
                    break;
                }
                std::thread::sleep(std::time::Duration::from_millis(2));
            }
        });

        let started = std::time::Instant::now();
        prepare_with_timeout(
            &mut client,
            "term_1".into(),
            false,
            std::time::Duration::from_millis(20),
        )
        .expect_err("continuous stale traffic must not extend semantic startup");
        assert!(started.elapsed() < std::time::Duration::from_secs(1));
        release_tx.send(()).expect("release fake server");
        fake_server.join().expect("fake server");
        let _ = std::fs::remove_file(path);
    }
}
