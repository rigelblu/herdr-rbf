//! Which full clients receive a notification about one pane (`hrdr-30.1`).

use super::*;

type Receiver = std::sync::mpsc::Receiver<Vec<u8>>;

struct RoutingServer {
    server: HeadlessServer,
    pane_b: crate::layout::PaneId,
    pane_c: crate::layout::PaneId,
    /// Full client attached to pane A's terminal.
    attached_a: Receiver,
    /// Full client attached to pane B's terminal.
    attached_b: Receiver,
    /// Full client showing the workspace view.
    workspace_view: Receiver,
    /// Full client with no presentation recorded yet.
    no_presentation: Receiver,
    /// Direct-attach client on pane B's terminal: not a full client.
    direct_attach_b: Receiver,
}

fn add_client(
    server: &mut HeadlessServer,
    client_id: u64,
    mode: ClientConnectionMode,
    presentation: Option<crate::server::clients::ClientShellPresentation>,
) -> Receiver {
    let (writer, control, _frames) = test_client_writer();
    let mut client = ClientConnection::new_with_mode(
        mode,
        (80, 24),
        crate::kitty_graphics::HostCellSize::default(),
        client_id,
        RenderEncoding::SemanticFrame,
        Some(writer),
    );
    client.shell_presentation = presentation;
    server.clients.insert(client_id, client);
    control
}

/// A server whose workspaces are `names`, with each workspace's root pane and its terminal id.
fn server_with_workspaces<const N: usize>(
    names: [&str; N],
) -> (HeadlessServer, [crate::layout::PaneId; N], [String; N]) {
    let mut server = test_headless_server();
    let workspaces = names.map(crate::workspace::Workspace::test_new);
    let panes = workspaces.each_ref().map(|ws| ws.tabs[0].root_pane);
    let terminal_ids = std::array::from_fn::<_, N, _>(|index| {
        workspaces[index]
            .terminal_id(panes[index])
            .expect("terminal id")
            .to_string()
    });
    server.app.state.workspaces = workspaces.into();
    server.app.state.ensure_test_terminals();
    server.app.state.active = Some(0);
    server.app.state.toast_config.delay_seconds = 0;
    (server, panes, terminal_ids)
}

fn routing_server() -> RoutingServer {
    let (mut server, panes, terminal_ids) = server_with_workspaces(["a", "b", "c"]);

    use crate::server::clients::{ClientShellLocation, ClientShellPresentation};
    let attached = |terminal_id: &String| {
        Some(ClientShellPresentation::AttachedTerminal {
            terminal_id: terminal_id.clone(),
        })
    };
    let attached_a = add_client(
        &mut server,
        1,
        ClientConnectionMode::ClientShell,
        attached(&terminal_ids[0]),
    );
    let attached_b = add_client(
        &mut server,
        2,
        ClientConnectionMode::ClientShell,
        attached(&terminal_ids[1]),
    );
    let workspace_view = add_client(
        &mut server,
        3,
        ClientConnectionMode::ClientShell,
        Some(ClientShellPresentation::Workspace(
            ClientShellLocation::default(),
        )),
    );
    let no_presentation = add_client(&mut server, 4, ClientConnectionMode::ClientShell, None);
    let direct_attach_b = add_client(
        &mut server,
        5,
        ClientConnectionMode::TerminalAttach {
            terminal_id: terminal_ids[1].clone(),
        },
        None,
    );
    RoutingServer {
        server,
        pane_b: panes[1],
        pane_c: panes[2],
        attached_a,
        attached_b,
        workspace_view,
        no_presentation,
        direct_attach_b,
    }
}

/// An agent in the pane's workspace changes from working to `state`: `Idle` finishes, `Blocked`
/// needs attention. Returns whether a client received the notification.
fn transition(
    server: &mut HeadlessServer,
    ws_idx: usize,
    pane_id: crate::layout::PaneId,
    state: crate::detect::AgentState,
) -> bool {
    server.forward_semantic_agent_transition(
        ws_idx,
        pane_id,
        crate::detect::AgentState::Working,
        state,
        Some("pi"),
        Some("pi"),
        Some(crate::detect::Agent::Pi),
    )
}

const FINISH: crate::detect::AgentState = crate::detect::AgentState::Idle;
const BLOCK: crate::detect::AgentState = crate::detect::AgentState::Blocked;

/// Everything the client received. Call it after the server is dropped: that closes the writer
/// queue, the drain thread exits and drops its sender, and `iter()` ends once the channel is
/// empty. So "nothing" is exact, with no timeout for a late message to slip past.
fn received(receiver: &Receiver) -> Vec<protocol::SemanticNotification> {
    receiver
        .iter()
        .filter_map(|bytes| match read_server_message(bytes) {
            ServerMessage::SemanticNotification(notification) => Some(notification),
            _ => None,
        })
        .collect()
}

fn titles(receiver: &Receiver) -> Vec<String> {
    received(receiver)
        .into_iter()
        .map(|notification| notification.title)
        .collect()
}

#[test]
fn pane_notification_reaches_its_attached_client_and_full_views_only() {
    let mut routing = routing_server();

    assert!(transition(&mut routing.server, 1, routing.pane_b, FINISH));
    drop(routing.server);

    let finished = vec!["pi finished".to_string()];
    assert_eq!(titles(&routing.attached_b), finished, "attached to B");
    assert_eq!(titles(&routing.workspace_view), finished, "workspace view");
    assert_eq!(
        titles(&routing.no_presentation),
        finished,
        "no presentation"
    );
    assert_eq!(
        titles(&routing.attached_a),
        Vec::<String>::new(),
        "attached to A must not get B's notification"
    );
    assert_eq!(
        titles(&routing.direct_attach_b),
        Vec::<String>::new(),
        "a direct-attach client is not a full client"
    );
}

#[test]
fn pane_notification_for_a_pane_with_no_attach_client_reaches_only_full_views() {
    let mut routing = routing_server();

    assert!(transition(&mut routing.server, 2, routing.pane_c, FINISH));
    drop(routing.server);

    let finished = vec!["pi finished".to_string()];
    assert_eq!(titles(&routing.workspace_view), finished, "workspace view");
    assert_eq!(
        titles(&routing.no_presentation),
        finished,
        "no presentation"
    );
    for (name, receiver) in [
        ("attached to A", &routing.attached_a),
        ("attached to B", &routing.attached_b),
        ("direct attach to B", &routing.direct_attach_b),
    ] {
        assert_eq!(
            titles(receiver),
            Vec::<String>::new(),
            "{name} must not get an untabbed pane's notification"
        );
    }
}

#[test]
fn notifications_with_no_pane_still_reach_every_full_client() {
    use protocol::SemanticNotificationKind::{Custom, UpdateInstalled};

    let mut routing = routing_server();

    let response = routing.server.handle_notification_show_api(
        "notify-show".into(),
        api::schema::NotificationShowParams {
            title: "plugin title".into(),
            body: None,
            position: None,
            sound: api::schema::NotificationShowSound::None,
        },
    );
    let response: api::schema::SuccessResponse = serde_json::from_str(&response).unwrap();
    assert!(matches!(
        response.result,
        api::schema::ResponseResult::NotificationShow { shown: true, .. }
    ));
    assert!(routing
        .server
        .handle_internal_event_with_forwarding(AppEvent::UpdateReady {
            version: "9.9.9".into(),
            install_command: "herdr update".into(),
        }));

    drop(routing.server);

    for (name, receiver) in [
        ("attached to A", &routing.attached_a),
        ("attached to B", &routing.attached_b),
        ("workspace view", &routing.workspace_view),
        ("no presentation", &routing.no_presentation),
    ] {
        let kinds = received(receiver)
            .into_iter()
            .map(|notification| notification.kind)
            .collect::<Vec<_>>();
        assert_eq!(
            kinds,
            vec![Custom, UpdateInstalled],
            "{name} gets the notification-show and the update notification"
        );
    }
    assert_eq!(
        titles(&routing.direct_attach_b),
        Vec::<String>::new(),
        "a direct-attach client is not a full client"
    );
}

#[test]
fn needs_attention_routes_like_finished() {
    let mut routing = routing_server();

    assert!(transition(&mut routing.server, 1, routing.pane_b, BLOCK));
    drop(routing.server);

    let sent = |receiver: &Receiver| {
        received(receiver)
            .into_iter()
            .map(|notification| (notification.kind, notification.title))
            .collect::<Vec<_>>()
    };
    let needs_attention = vec![(
        protocol::SemanticNotificationKind::NeedsAttention,
        "pi needs attention".to_string(),
    )];
    assert_eq!(sent(&routing.attached_b), needs_attention, "attached to B");
    assert_eq!(
        sent(&routing.workspace_view),
        needs_attention,
        "workspace view"
    );
    assert_eq!(
        sent(&routing.no_presentation),
        needs_attention,
        "no presentation"
    );
    assert!(
        sent(&routing.attached_a).is_empty(),
        "attached to A must not get B's notification"
    );
    assert!(
        sent(&routing.direct_attach_b).is_empty(),
        "a direct-attach client is not a full client"
    );
}

#[test]
fn a_client_with_no_writer_is_not_a_pane_notification_recipient() {
    let (mut server, [pane], _) = server_with_workspaces(["a"]);
    server.clients.insert(
        1,
        ClientConnection::new_with_mode(
            ClientConnectionMode::ClientShell,
            (80, 24),
            crate::kitty_graphics::HostCellSize::default(),
            1,
            RenderEncoding::SemanticFrame,
            None,
        ),
    );

    assert!(
        !transition(&mut server, 0, pane, FINISH),
        "a writer-less client is the only candidate, so nothing was sent"
    );
}

#[test]
fn a_notification_for_a_pane_that_is_gone_reaches_only_full_views() {
    // The pane closes before its notification is built: the workspace can't name its terminal,
    // so no attach client is the pane's viewer.
    let mut routing = routing_server();
    let missing_pane = crate::layout::PaneId::alloc();

    let sent = routing.server.send_pane_notification(
        0,
        missing_pane,
        ServerMessage::SemanticNotification(protocol::SemanticNotification {
            kind: protocol::SemanticNotificationKind::Finished,
            title: "pi finished".into(),
            body: None,
            sound: None,
            agent: None,
            workspace_id: None,
            tab_id: None,
            pane_id: None,
            position: None,
        }),
    );
    drop(routing.server);

    assert!(sent, "full views still receive it");
    let finished = vec!["pi finished".to_string()];
    assert_eq!(titles(&routing.workspace_view), finished, "workspace view");
    assert_eq!(
        titles(&routing.no_presentation),
        finished,
        "no presentation"
    );
    for (name, receiver) in [
        ("attached to A", &routing.attached_a),
        ("attached to B", &routing.attached_b),
        ("direct attach to B", &routing.direct_attach_b),
    ] {
        assert_eq!(
            titles(receiver),
            Vec::<String>::new(),
            "{name} must not get a gone pane's notification"
        );
    }
}
