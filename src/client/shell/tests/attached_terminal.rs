use super::*;

#[test]
fn attached_terminal_does_not_paint_workspace_chrome_before_its_surface_is_ready() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);

    assert!(state.compose(80, 20).is_none());
    state.set_snapshot(Box::new(snapshot()));
    assert!(state.compose(80, 20).is_none());

    state.set_pane_surface(surface());
    assert!(state.compose(80, 20).is_some());
}

#[test]
fn attached_terminal_uses_the_whole_host_for_the_pane_surface_without_shell_chrome() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());

    let frame = state.compose(4, 2).expect("attached terminal frame");

    assert_eq!(frame_rows(&frame), ["LIVE", "PANE"]);
    assert_eq!(state.hits.panes.len(), 1);
    assert_eq!(state.hits.panes[0].rect, Rect::new(0, 0, 4, 2));
    assert_eq!(state.hits.panes[0].inner_rect, Rect::new(0, 0, 4, 2));
    assert!(state.hits.tabs.is_empty());
    assert!(state.hits.workspaces.is_empty());
    assert!(state.hits.sidebar_toggle.is_empty());
}

#[test]
fn attached_terminal_retained_patch_keeps_surface_coordinates() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);
    state.set_snapshot(Box::new(snapshot()));
    let pane_surface = surface();
    let mut updated_pane = pane_surface.panes[0].clone();
    updated_pane.content_revision = 2;
    state.set_pane_surface(pane_surface);
    let composed = state.compose(80, 20).expect("initial attached frame");
    let patch = crate::protocol::PaneSurfacePatch {
        boot_id: "boot-1".into(),
        projection_revision: 1,
        base_surface_revision: 1,
        surface_revision: 2,
        rows: vec![crate::protocol::PaneSurfacePatchRow {
            x: 0,
            y: 0,
            cells: vec![crate::protocol::CellData {
                symbol: "N".into(),
                fg: 0,
                bg: 0,
                modifier: 0,
                skip: false,
                hyperlink: None,
            }],
        }],
        panes: vec![updated_pane],
        cursor: Some(crate::protocol::CursorState {
            x: 1,
            y: 0,
            visible: true,
            shape: 2,
        }),
    };

    state.config_diagnostic = Some("hidden diagnostic".into());
    state.overlay = Some(ClientShellOverlay::Onboarding);
    let ClientPaneSurfacePatchOutcome::Applied(Some(patch)) = state.apply_pane_surface_patch(patch)
    else {
        panic!("hidden full-shell state must not block an attached retained patch");
    };

    assert_eq!((patch.rows[0].x, patch.rows[0].y), (0, 0));
    assert_eq!(
        patch.cursor.as_ref().map(|cursor| (cursor.x, cursor.y)),
        Some((1, 0))
    );
    let patched = apply_composed_surface_patch(&composed, patch).expect("apply composed patch");
    assert_eq!(patched.cells[0].symbol, "N");
}

#[test]
fn attached_terminal_ignores_product_announcements() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);
    let mut attached_snapshot = snapshot();
    attached_snapshot.product_announcement =
        Some(crate::protocol::ClientShellProductAnnouncement {
            version: "0.8.2".into(),
            id: "announcement".into(),
            title: "Hidden announcement".into(),
            body: "This must not capture attached-terminal input.".into(),
            preview: false,
        });

    state.set_snapshot(Box::new(attached_snapshot));

    assert!(state.overlay.is_none());
}

#[test]
fn attached_terminal_keeps_only_the_direct_attach_escape_commands() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());

    assert!(state.handle_input_bytes(&[0x02]).requests.is_empty());
    assert!(state.handle_input_bytes(b"q").detach);

    let mut state = ClientShellState::new(
        ClientShellConfig::from_config(&Config::default()).with_attached_terminal(),
    );
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    assert!(state.handle_input_bytes(&[0x02]).requests.is_empty());
    let literal = state.handle_input_bytes(&[0x02]);
    assert!(matches!(
        &literal.requests[..],
        [crate::protocol::ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(&events[..], [crate::protocol::ClientPaneInputEvent::Key {
                    code: crate::protocol::ClientKeyCode::Char('b'),
                    modifiers,
                    kind: crate::protocol::ClientKeyKind::Press,
                    ..
                }] if *modifiers == KeyModifiers::CONTROL.bits())
    ));
}

#[test]
fn attached_terminal_forwards_full_shell_direct_bindings_to_the_child() {
    let config = ClientShellConfig::from_config(&Config::default()).with_attached_terminal();
    let mut state = ClientShellState::new(config);
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());

    let outcome = state.handle_raw_events(vec![RawInputEvent::Key(
        crate::input::TerminalKey::new(KeyCode::Char('k'), KeyModifiers::SUPER),
    )]);

    assert!(outcome.actions.is_empty());
    assert!(matches!(
        &outcome.requests[..],
        [crate::protocol::ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(&events[..], [crate::protocol::ClientPaneInputEvent::Key {
                    code: crate::protocol::ClientKeyCode::Char('k'),
                    modifiers,
                    kind: crate::protocol::ClientKeyKind::Press,
                    ..
                }] if *modifiers == KeyModifiers::SUPER.bits())
    ));
}

#[test]
fn attached_terminal_ordinary_drag_highlights_and_copies_joined_text() {
    let mut config = Config::default();
    config.ui.copy_on_select = true;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.set_endpoint_methods(Some(vec!["pane.selection.read_joined".into()]));
    let original = state.compose(4, 2).expect("initial attached frame");

    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };
    let down = state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)]);
    assert!(
        down.actions.is_empty(),
        "selection must not request pane.focus"
    );
    state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)]);
    let selected = state.compose(4, 2).expect("selected attached frame");
    assert_ne!(
        (
            selected.cells[0].fg,
            selected.cells[0].bg,
            selected.cells[0].modifier,
        ),
        (
            original.cells[0].fg,
            original.cells[0].bg,
            original.cells[0].modifier,
        )
    );

    let release = state.handle_raw_events(vec![mouse(MouseEventKind::Up(MouseButton::Left), 2)]);
    assert!(matches!(
        &release.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(request.method,
                crate::api::schema::Method::PaneSelectionReadJoined(_))
    ));
    assert!(state.selection.is_none());
}

#[test]
fn attached_terminal_without_mouse_reporting_keeps_drag_local_and_routes_wheel_to_the_pane() {
    let mut config = Config::default();
    config.ui.copy_on_select = false;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(4, 2).expect("initial attached frame");
    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };

    assert!(state
        .handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)])
        .requests
        .is_empty());
    assert!(state
        .handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)])
        .requests
        .is_empty());
    assert!(state.selection.is_some());

    let wheel = state.handle_raw_events(vec![mouse(MouseEventKind::ScrollUp, 1)]);
    assert!(matches!(
        &wheel.requests[..],
        [crate::protocol::ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(events.as_slice(), [crate::protocol::ClientPaneInputEvent::Mouse {
                    kind: crate::protocol::ClientMouseKind::ScrollUp,
                    ..
                }])
    ));
}

#[test]
fn attached_terminal_falls_back_to_plain_selection_read_when_joined_read_is_unavailable() {
    let mut config = Config::default();
    config.ui.copy_on_select = true;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.set_endpoint_methods(Some(vec!["pane.selection.read".into()]));
    state.compose(4, 2).expect("initial attached frame");
    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };
    state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)]);

    let release = state.handle_raw_events(vec![mouse(MouseEventKind::Up(MouseButton::Left), 2)]);
    assert!(matches!(
        &release.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(request.method, crate::api::schema::Method::PaneSelectionRead(_))
    ));
}

#[test]
fn attached_terminal_invalidates_changed_or_resized_selection_with_feedback() {
    for resize in [false, true] {
        let mut config = Config::default();
        config.ui.copy_on_select = false;
        let mut state =
            ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
        state.set_snapshot(Box::new(snapshot()));
        state.set_pane_surface(surface());
        state.compose(4, 2).expect("initial attached frame");
        let mouse = |kind, column| {
            RawInputEvent::Mouse(MouseEvent {
                kind,
                column,
                row: 0,
                modifiers: KeyModifiers::empty(),
            })
        };
        state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)]);
        state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)]);
        state.handle_raw_events(vec![mouse(MouseEventKind::Up(MouseButton::Left), 2)]);
        assert!(state.selection.is_some());

        let mut changed = state.pane_surface.clone().expect("pane surface");
        changed.surface_revision += 1;
        changed.panes[0].content_revision += 2;
        if resize {
            changed.panes[0].inner_rect.width -= 1;
        } else {
            changed.frame.cells[0].symbol = "X".into();
        }
        state.set_pane_surface(changed);

        assert!(state.selection.is_none());
        assert_eq!(
            state
                .copy_feedback
                .as_ref()
                .map(|feedback| feedback.message.as_str()),
            Some("selection changed · drag again")
        );
    }
}

#[test]
fn attached_terminal_preserves_selection_for_unrelated_output_and_cancels_during_drag() {
    let mut config = Config::default();
    config.ui.copy_on_select = false;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(4, 2).expect("initial attached frame");
    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };
    state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)]);

    let mut unrelated = state.pane_surface.clone().expect("pane surface");
    unrelated.surface_revision += 1;
    unrelated.panes[0].content_revision += 2;
    unrelated.frame.cells[4].symbol = "X".into();
    state.set_pane_surface(unrelated);
    assert!(state.selection.is_some());
    assert!(state.copy_feedback.is_none());

    let mut selected = state.pane_surface.clone().expect("pane surface");
    selected.surface_revision += 1;
    selected.panes[0].content_revision += 2;
    selected.frame.cells[0].symbol = "Y".into();
    state.set_pane_surface(selected);
    assert!(state.selection.is_none());
    assert_eq!(
        state
            .copy_feedback
            .as_ref()
            .map(|feedback| feedback.message.as_str()),
        Some("selection changed · drag again")
    );
}

#[test]
fn attached_terminal_mouse_reporting_takes_drag_and_wheel_without_stale_selection() {
    let mut config = Config::default();
    config.ui.copy_on_select = false;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(4, 2).expect("initial attached frame");
    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };
    state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 2)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 0)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Up(MouseButton::Left), 0)]);
    assert!(state.selection.is_some());

    let mut reporting = state.pane_surface.clone().expect("pane surface");
    reporting.surface_revision += 1;
    reporting.panes[0].mouse_reporting = true;
    state.set_pane_surface(reporting);
    state.compose(4, 2).expect("mouse-reporting frame");

    assert!(state.selection.is_none());
    assert!(state.copy_feedback.is_none());
    assert!(state
        .handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)])
        .requests
        .is_empty());
    for kind in [
        MouseEventKind::Down(MouseButton::Left),
        MouseEventKind::ScrollUp,
    ] {
        assert!(matches!(
            &state.handle_raw_events(vec![mouse(kind, 1)]).requests[..],
            [crate::protocol::ClientMessage::ClientShellPaneInput { pane_id, events }]
                if pane_id == "pane_1" && matches!(events.as_slice(), [crate::protocol::ClientPaneInputEvent::Mouse { .. }])
        ));
    }
}

#[test]
fn attached_terminal_retained_selection_ctrl_c_copies_joined_text() {
    let mut config = Config::default();
    config.ui.copy_on_select = false;
    let mut state =
        ClientShellState::new(ClientShellConfig::from_config(&config).with_attached_terminal());
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.set_endpoint_methods(Some(vec!["pane.selection.read_joined".into()]));
    state.compose(4, 2).expect("initial attached frame");
    let mouse = |kind, column| {
        RawInputEvent::Mouse(MouseEvent {
            kind,
            column,
            row: 0,
            modifiers: KeyModifiers::empty(),
        })
    };
    state.handle_raw_events(vec![mouse(MouseEventKind::Down(MouseButton::Left), 0)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Drag(MouseButton::Left), 2)]);
    state.handle_raw_events(vec![mouse(MouseEventKind::Up(MouseButton::Left), 2)]);

    let copy = state.handle_raw_events(vec![RawInputEvent::Key(crate::input::TerminalKey::new(
        KeyCode::Char('c'),
        KeyModifiers::CONTROL,
    ))]);
    assert!(matches!(
        &copy.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(request.method, crate::api::schema::Method::PaneSelectionReadJoined(_))
    ));
    assert!(state.selection.is_none());
}
