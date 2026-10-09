use super::*;

#[test]
fn selection_repaint_cadence_keeps_one_deadline_and_flushes_when_input_stops() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    let now = std::time::Instant::now();
    let ms = std::time::Duration::from_millis;
    state.last_composed_at = Some(now);
    for elapsed in [1, 4, 8, 12, 15] {
        assert!(!state.request_selection_drag_repaint(now + ms(elapsed)));
        assert_eq!(state.selection_repaint_deadline, Some(now + ms(16)));
    }
    assert_eq!(state.timer_delay(now + ms(8)), ms(8));
    assert!(!state.tick_selection_autoscroll(now + ms(15)).repaint);
    assert!(state.tick_selection_autoscroll(now + ms(16)).repaint);
    assert!(state.selection_repaint_deadline.is_none());
    assert!(!state.tick_selection_autoscroll(now + ms(17)).repaint);
}

#[test]
fn selection_repaint_cadence_allows_immediate_paint_when_due() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    let now = std::time::Instant::now();
    assert!(state.request_selection_drag_repaint(now));
    state.last_composed_at = Some(now);
    assert!(state.request_selection_drag_repaint(now + std::time::Duration::from_millis(16)));
    assert!(state.selection_repaint_deadline.is_none());
}

#[test]
fn selection_repaint_cadence_does_not_leave_work_after_another_composition() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    let now = std::time::Instant::now();
    state.selection_repaint_deadline = Some(now);
    state.compose(106, 20).expect("frame");
    assert!(state.selection_repaint_deadline.is_none());
    assert!(!state.tick_selection_autoscroll(now).repaint);
}

#[test]
fn selection_release_copies_latest_position_before_deferred_paint() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("pane frame");
    let pane = state.hits.panes[0].clone();
    let mut mouse = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane.inner_rect.x,
        row: pane.inner_rect.y,
        modifiers: KeyModifiers::empty(),
    };
    state.handle_raw_events(vec![RawInputEvent::Mouse(mouse)]);
    mouse.kind = MouseEventKind::Drag(MouseButton::Left);
    mouse.column += 2;
    state.handle_raw_events(vec![RawInputEvent::Mouse(mouse)]);
    state.selection_repaint_deadline = Some(std::time::Instant::now());
    mouse.kind = MouseEventKind::Up(MouseButton::Left);
    let release = state.handle_raw_events(vec![RawInputEvent::Mouse(mouse)]);
    assert!(release.repaint);
    assert!(matches!(
        &release.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(&request.method,
                crate::api::schema::Method::PaneSelectionRead(params)
                    if params.cursor == crate::api::schema::PaneTextPoint { row: 0, col: 2 })
    ));
    state.compose(106, 20).expect("release frame");
    assert!(state.selection_repaint_deadline.is_none());
}

#[test]
fn ctrl_click_routes_link_activation_through_endpoint_then_client_host() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("pane frame");
    let pane = state.hits.panes[0].clone();
    let down = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane.inner_rect.x + 2,
        row: pane.inner_rect.y + 1,
        modifiers: KeyModifiers::CONTROL,
    };
    let activate = state.handle_raw_events(vec![RawInputEvent::Mouse(down)]);
    let [ClientShellAction::Endpoint { request, .. }] = &activate.actions[..] else {
        panic!("expected link activation request");
    };
    let request_id = request.id.clone();
    assert!(matches!(
        &request.method,
        crate::api::schema::Method::PaneLinkActivate(params)
            if params.pane_id == "pane_1" && params.viewport_row == 1 && params.col == 2
    ));

    let up = MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        ..down
    };
    let held = state.handle_raw_events(vec![RawInputEvent::Mouse(up)]);
    assert!(held.requests.is_empty() && held.actions.is_empty());
    let (_, actions) = state.handle_endpoint_result(
        "boot-1",
        &request_id,
        Ok(crate::api::schema::ResponseResult::PaneLinkActivated {
            url: Some("https://example.test".to_owned()),
            handled: false,
        }),
    );
    assert!(matches!(
        &actions[..],
        [ClientShellAction::OpenSafeWebUrl(url)] if url == "https://example.test"
    ));
    assert!(!state.url_click_consumes_until_up);
}

#[test]
fn ctrl_click_without_a_link_replays_the_original_gesture() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("pane frame");
    let pane = state.hits.panes[0].clone();
    let down = MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane.inner_rect.x + 2,
        row: pane.inner_rect.y + 1,
        modifiers: KeyModifiers::CONTROL,
    };
    let activate = state.handle_raw_events(vec![RawInputEvent::Mouse(down)]);
    let request_id = match &activate.actions[..] {
        [ClientShellAction::Endpoint { request, .. }] => request.id.clone(),
        _ => panic!("expected link activation request"),
    };
    let (_, actions) = state.handle_endpoint_result(
        "boot-1",
        &request_id,
        Ok(crate::api::schema::ResponseResult::PaneLinkActivated {
            url: None,
            handled: false,
        }),
    );
    assert!(matches!(
        &actions[..],
        [ClientShellAction::ReplayMouse(events)] if events == &vec![down]
    ));
    let replay = match actions.into_iter().next().expect("replay action") {
        ClientShellAction::ReplayMouse(events) => state.replay_mouse_events(events),
        _ => unreachable!(),
    };
    assert!(matches!(
        &replay.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(request.method, crate::api::schema::Method::PaneFocus(_))
    ));
    assert!(state.selection.is_some());
}

#[test]
fn pane_split_drag_uses_projected_handle_and_stable_tab_path() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    let mut pane_surface = surface();
    pane_surface.splits.push(PaneSurfaceSplit {
        direction: PaneSurfaceSplitDirection::Horizontal,
        pos: 40,
        area: SurfaceRect {
            x: 0,
            y: 0,
            width: 80,
            height: 19,
        },
        hit_rect: SurfaceRect {
            x: 40,
            y: 0,
            width: 1,
            height: 19,
        },
        path: vec![false, true],
    });
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("split pane surface");
    let split = state.hits.pane_splits[0].clone();

    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: split.hit_rect.x,
        row: split.hit_rect.y + 2,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        state.chrome_drag,
        Some(ClientChromeDrag::PaneSplit { .. })
    ));
    let mut replacement = snapshot();
    replacement.revision = 2;
    replacement
        .tab_bar_right
        .push(crate::protocol::ClientShellTabStatusSegment {
            text: "updated".into(),
            accent: false,
        });
    let mut replacement_surface = surface();
    replacement_surface.projection_revision = 2;
    replacement_surface.splits.push(PaneSurfaceSplit {
        direction: PaneSurfaceSplitDirection::Horizontal,
        pos: 40,
        area: SurfaceRect {
            x: 0,
            y: 0,
            width: 80,
            height: 19,
        },
        hit_rect: SurfaceRect {
            x: 40,
            y: 0,
            width: 1,
            height: 19,
        },
        path: vec![false, true],
    });
    state.set_snapshot(Box::new(replacement));
    state.set_pane_surface(replacement_surface);
    let drag = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: split.area.x + 48,
        row: split.hit_rect.y + 2,
        modifiers: KeyModifiers::empty(),
    })]);
    let [ClientShellAction::Endpoint { request, .. }] = &drag.actions[..] else {
        panic!("pane split drag should use endpoint API");
    };
    assert!(matches!(
        &request.method,
        crate::api::schema::Method::LayoutSetSplitRatio(params)
            if params.tab_id.as_deref() == Some("tab_1")
                && params.path == vec![false, true]
                && (params.ratio - 0.6).abs() < f32::EPSILON
    ));
    let release =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: split.area.x + 48,
            row: split.hit_rect.y + 2,
            modifiers: KeyModifiers::empty(),
        })]);
    assert!(release.actions.is_empty());
    assert!(state.chrome_drag.is_none());
}

#[test]
fn disabled_mouse_chrome_keeps_tab_wheel_but_removes_split_drag_hits() {
    let mut config = Config::default();
    config.ui.mouse_capture = false;
    let mut projected = snapshot();
    let mut second_tab = projected.tabs[0].clone();
    second_tab.tab_id = "tab_2".into();
    second_tab.number = 2;
    second_tab.label = "2".into();
    second_tab.focused = false;
    projected.tabs.push(second_tab);
    let mut pane_surface = surface();
    pane_surface.splits.push(PaneSurfaceSplit {
        direction: PaneSurfaceSplitDirection::Horizontal,
        pos: 40,
        area: SurfaceRect {
            x: 0,
            y: 0,
            width: 80,
            height: 19,
        },
        hit_rect: SurfaceRect {
            x: 40,
            y: 0,
            width: 1,
            height: 19,
        },
        path: Vec::new(),
    });
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&config));
    state.set_snapshot(Box::new(projected));
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("mouse-disabled shell");
    assert!(state.hits.pane_splits.is_empty());
    let first_tab = state.hits.tabs[0].0;
    let wheel = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::ScrollDown,
        column: first_tab.x,
        row: first_tab.y,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        &wheel.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(
                &request.method,
                crate::api::schema::Method::TabFocus(target) if target.tab_id == "tab_2"
            )
    ));
}

#[test]
fn client_double_click_selects_word_and_copies_only_after_release() {
    for (copy_on_select, release_before_response) in [(false, true), (true, false)] {
        let mut state = word_drag_state(copy_on_select);
        let initial = start_word_drag(&mut state);
        let release = MouseEventKind::Up(MouseButton::Left);
        if release_before_response {
            assert!(word_drag_mouse(&mut state, release, 0, 8)
                .actions
                .is_empty());
        }
        let mut actions = word_row_reply(&mut state, &initial, "alpha bravo charlie");
        if !release_before_response {
            assert!(actions.is_empty(), "holding the second press must not copy");
            assert!(state.selection.as_ref().unwrap().is_in_progress());
            state.tick_copy_feedback(std::time::Instant::now() + std::time::Duration::from_secs(1));
            assert!(state.selection.as_ref().unwrap().is_visible());
            assert!(state.copy_feedback.is_none());
            actions = word_drag_mouse(&mut state, release, 0, 8).actions;
        }
        assert!(state.selection.as_ref().unwrap().is_finalized());
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 6), (0, 10))
        );
        assert!(
            word_drag_mouse(&mut state, release, 0, 8)
                .actions
                .is_empty(),
            "copy only once"
        );
        if copy_on_select {
            assert!(
                matches!(&actions[..], [ClientShellAction::Endpoint { request, .. }]
                if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                    if params.anchor.col == 6 && params.cursor.col == 10))
            );
            let copied = word_row_reply(&mut state, &word_read_id(&actions), "bravo");
            assert!(
                matches!(&copied[..], [ClientShellAction::ClipboardWrite(bytes)] if bytes == b"bravo")
            );
            assert!(state.tick_copy_feedback(state.selection_highlight_clear_deadline.unwrap()));
            assert!(state.selection.is_none());
        } else {
            assert!(actions.is_empty(), "manual selection must not auto-copy");
            state.tick_copy_feedback(std::time::Instant::now() + std::time::Duration::from_secs(1));
            assert!(
                state.selection.is_some(),
                "manual selection must not expire"
            );
        }
    }
}

#[test]
fn client_triple_click_selects_full_row_and_copies_only_after_release() {
    for copy_on_select in [true, false] {
        let mut state = word_drag_state(copy_on_select);
        let down = MouseEventKind::Down(MouseButton::Left);
        let up = MouseEventKind::Up(MouseButton::Left);

        // Click 1
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 2
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 3 (held)
        let held = word_drag_mouse(&mut state, down, 0, 8);
        assert!(
            !held.actions.iter().any(|action| matches!(
                action,
                ClientShellAction::Endpoint { request, .. }
                    if matches!(
                        &request.method,
                        crate::api::schema::Method::PaneSelectionRead(_)
                            | crate::api::schema::Method::PaneSelectionReadJoined(_)
                    )
            )),
            "holding third press must not copy"
        );
        assert!(
            state.selection.is_some(),
            "triple click should create selection"
        );
        let selection = state.selection.as_ref().unwrap();
        assert!(
            selection.is_in_progress(),
            "selection must be in progress while held"
        );
        assert_eq!(
            selection.ordered_cells(),
            ((0, 0), (0, 18)),
            "triple click must select full visual row (0..width-1)"
        );

        // Release Click 3
        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(state.selection.as_ref().unwrap().is_finalized());

        if copy_on_select {
            assert!(
                matches!(&released.actions[..], [ClientShellAction::Endpoint { request, .. }]
                if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                    | crate::api::schema::Method::PaneSelectionReadJoined(params)
                    if params.anchor.row == 0 && params.anchor.col == 0 && params.cursor.row == 0 && params.cursor.col == 18))
            );
            let copied = word_row_reply(
                &mut state,
                &word_read_id(&released.actions),
                "alpha bravo charlie",
            );
            assert!(
                matches!(&copied[..], [ClientShellAction::ClipboardWrite(bytes)] if bytes == b"alpha bravo charlie")
            );
            assert!(
                state.selection.is_some(),
                "selection highlight must flash for 500ms"
            );
            assert!(state.tick_copy_feedback(state.selection_highlight_clear_deadline.unwrap()));
            assert!(
                state.selection.is_none(),
                "selection cleared after highlight flash"
            );
        } else {
            assert!(
                !released.actions.iter().any(|action| matches!(
                    action,
                    ClientShellAction::Endpoint { request, .. }
                        if matches!(
                            &request.method,
                            crate::api::schema::Method::PaneSelectionRead(_)
                                | crate::api::schema::Method::PaneSelectionReadJoined(_)
                        )
                )),
                "manual selection must not auto-copy"
            );
            state.tick_copy_feedback(std::time::Instant::now() + std::time::Duration::from_secs(1));
            assert!(
                state.selection.is_some(),
                "manual selection must not expire"
            );

            // Copy with Ctrl+C
            let ctrl_c =
                state.handle_raw_events(vec![RawInputEvent::Key(crate::input::TerminalKey::new(
                    crossterm::event::KeyCode::Char('c'),
                    crossterm::event::KeyModifiers::CONTROL,
                ))]);
            assert!(
                matches!(&ctrl_c.actions[..], [ClientShellAction::Endpoint { request, .. }]
                if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                    | crate::api::schema::Method::PaneSelectionReadJoined(params)
                    if params.anchor.row == 0 && params.anchor.col == 0 && params.cursor.row == 0 && params.cursor.col == 18))
            );
            assert!(
                state.selection.is_none(),
                "Ctrl+C clears selection after copy request"
            );
        }
    }
}

#[test]
fn client_triple_click_interval_and_distance_bounds() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // 1. Exact 350ms vs 351ms predicate unit contract
    let now = std::time::Instant::now();
    let click = ClientPaneClick {
        pane_id: "pane_1".into(),
        viewport_row: 0,
        col: 8,
        at: now,
        count: 2,
        focus_confirmed: true,
    };
    assert!(
        click.is_subsequent_click_for(now + std::time::Duration::from_millis(350), 0, 8, "pane_1"),
        "350ms inclusive interval must qualify"
    );
    assert!(
        !click.is_subsequent_click_for(now + std::time::Duration::from_millis(351), 0, 8, "pane_1"),
        "351ms exclusive interval must not qualify"
    );

    // 2. Event pipeline interval check: within timeout qualifies, expired resets
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 3 within interval (200ms)
        state.last_pane_click.as_mut().unwrap().at =
            std::time::Instant::now() - std::time::Duration::from_millis(200);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.selection.is_some());
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "click within interval must advance to line selection"
        );
    }
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 3 expired (>350ms)
        state.last_pane_click.as_mut().unwrap().at =
            std::time::Instant::now() - std::time::Duration::from_millis(400);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.selection.is_some());
        assert!(
            state.selection.as_ref().unwrap().is_just_click(),
            "expired interval must reset sequence to single cell anchor"
        );
    }

    // 3. Row distance tolerance: abs_diff <= 1 passes, > 1 fails
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // row 1 is distance 1 from row 0 -> passes
        word_drag_mouse(&mut state, down, 1, 8);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((1, 0), (1, 18)),
            "row distance <= 1 qualifies for third click"
        );
    }
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // row 2 is distance 2 from row 0 -> fails
        word_drag_mouse(&mut state, down, 2, 8);
        assert!(
            state.selection.as_ref().unwrap().is_just_click(),
            "row distance > 1 resets sequence to single cell anchor"
        );
    }

    // 4. Col distance tolerance: abs_diff <= 1 passes, > 1 fails
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // col 9 is distance 1 from col 8 -> passes
        word_drag_mouse(&mut state, down, 0, 9);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "col distance <= 1 qualifies for third click"
        );
    }
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // col 10 is distance 2 from col 8 -> fails
        word_drag_mouse(&mut state, down, 0, 10);
        assert!(
            state.selection.as_ref().unwrap().is_just_click(),
            "col distance > 1 resets sequence to single cell anchor"
        );
    }

    // 5. Shift modifier breaks sequence
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        let pane = state.hits.panes[0].clone();
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: down,
            column: pane.inner_rect.x + 8,
            row: pane.inner_rect.y,
            modifiers: KeyModifiers::SHIFT,
        })]);
        assert!(
            state.selection.as_ref().unwrap().is_just_click(),
            "modified click resets sequence to single cell anchor"
        );
        assert!(
            state.last_pane_click.is_none(),
            "modified click does not save click state"
        );
    }
}

#[test]
fn client_triple_click_fourth_click_cycles_to_single_cell() {
    let mut state = word_drag_state(false);
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // Click 1: single cell anchor
    word_drag_mouse(&mut state, down, 0, 8);
    assert!(state.selection.as_ref().unwrap().is_just_click());
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 1);
    word_drag_mouse(&mut state, up, 0, 8);

    // Click 2: word selection
    let req2 = word_drag_mouse(&mut state, down, 0, 8);
    assert!(req2
        .actions
        .iter()
        .any(|a| matches!(a, ClientShellAction::Endpoint { .. })));
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 2);
    word_drag_mouse(&mut state, up, 0, 8);

    // Click 3: line selection
    word_drag_mouse(&mut state, down, 0, 8);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 0), (0, 18))
    );
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 3);
    word_drag_mouse(&mut state, up, 0, 8);

    // Click 4: cycles 1/2/3/1 -> resets to single cell anchor
    word_drag_mouse(&mut state, down, 0, 8);
    assert!(
        state.selection.as_ref().unwrap().is_just_click(),
        "4th click must cycle to single cell anchor"
    );
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 1);
    word_drag_mouse(&mut state, up, 0, 8);

    // Click 5: advances to word selection (count 2)
    let req5 = word_drag_mouse(&mut state, down, 0, 8);
    assert!(req5
        .actions
        .iter()
        .any(|a| matches!(a, ClientShellAction::Endpoint { .. })));
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 2);
    word_drag_mouse(&mut state, up, 0, 8);

    // Click 6: advances to line selection (count 3)
    word_drag_mouse(&mut state, down, 0, 8);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 0), (0, 18))
    );
    assert_eq!(state.last_pane_click.as_ref().unwrap().count, 3);
}

#[test]
fn client_line_selection_vertical_and_reverse_drag() {
    let mut state = word_drag_state(true);
    let down = MouseEventKind::Down(MouseButton::Left);
    let drag = MouseEventKind::Drag(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // Triple click on row 1
    word_drag_mouse(&mut state, down, 1, 8);
    word_drag_mouse(&mut state, up, 1, 8);
    word_drag_mouse(&mut state, down, 1, 8);
    word_drag_mouse(&mut state, up, 1, 8);
    word_drag_mouse(&mut state, down, 1, 8);

    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((1, 0), (1, 18))
    );

    // Drag down to row 2
    word_drag_mouse(&mut state, drag, 2, 8);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((1, 0), (2, 18)),
        "vertical forward drag extends whole rows downwards"
    );

    // Drag up to row 0 (reverse drag past anchor row 1)
    word_drag_mouse(&mut state, drag, 0, 8);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 0), (1, 18)),
        "vertical reverse drag extends whole rows upwards"
    );

    // Horizontal movement on row 0 must never narrow endpoints
    for col in [0, 5, 12, 18] {
        word_drag_mouse(&mut state, drag, 0, col);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (1, 18)),
            "horizontal drag must not narrow endpoints"
        );
    }

    // Drag back to anchor row 1
    word_drag_mouse(&mut state, drag, 1, 8);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((1, 0), (1, 18))
    );

    // Release after drag with copy_on_select:
    // Dragged line selections are copied and immediately cleared (no 500ms flash)
    let released = word_drag_mouse(&mut state, up, 1, 8);
    assert!(
        matches!(&released.actions[..], [ClientShellAction::Endpoint { request, .. }]
        if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
            | crate::api::schema::Method::PaneSelectionReadJoined(params)
            if params.anchor.row == 1 && params.cursor.row == 1))
    );
    assert!(
        state.selection.is_none(),
        "dragged line selection clears immediately on release"
    );
}

#[test]
fn client_triple_click_supersedes_delayed_word_reply() {
    for reply_after_release in [false, true] {
        let mut state = word_drag_state(true);
        let down = MouseEventKind::Down(MouseButton::Left);
        let up = MouseEventKind::Up(MouseButton::Left);

        // Click 1
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 2 (word selection request sent, reply pending)
        let second = word_drag_mouse(&mut state, down, 0, 8);
        let word_req_id = word_read_id(&second.actions);
        word_drag_mouse(&mut state, up, 0, 8);

        // Click 3 pressed before word reply arrives
        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "line selection active on 3rd press"
        );

        if reply_after_release {
            // Release Click 3 first
            let release_actions = word_drag_mouse(&mut state, up, 0, 8).actions;
            assert!(
                matches!(&release_actions[..], [ClientShellAction::Endpoint { request, .. }]
                if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                    | crate::api::schema::Method::PaneSelectionReadJoined(params)
                    if params.anchor.col == 0 && params.cursor.col == 18)),
                "line selection copy must be enqueued on release"
            );

            // Delayed word reply arrives after release
            let delayed_actions = word_row_reply(&mut state, &word_req_id, "alpha bravo charlie");
            assert!(
                delayed_actions.is_empty(),
                "delayed word reply arriving after third release must be discarded"
            );
        } else {
            // Delayed word reply arrives while 3rd press is held
            let delayed_actions = word_row_reply(&mut state, &word_req_id, "alpha bravo charlie");
            assert!(
                delayed_actions.is_empty(),
                "delayed word reply must be discarded and emit no actions"
            );
            assert_eq!(
                state.selection.as_ref().unwrap().ordered_cells(),
                ((0, 0), (0, 18)),
                "line selection must not be overwritten by obsolete word reply"
            );

            // Release Click 3
            let release_actions = word_drag_mouse(&mut state, up, 0, 8).actions;
            assert!(
                matches!(&release_actions[..], [ClientShellAction::Endpoint { request, .. }]
                if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                    | crate::api::schema::Method::PaneSelectionReadJoined(params)
                    if params.anchor.col == 0 && params.cursor.col == 18)),
                "only line selection copy must be enqueued"
            );
        }
    }
}

fn empty_row_and_margin_state() -> ClientShellState {
    let mut config = Config::default();
    config.ui.copy_on_select = false;
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&config));
    state.set_snapshot(Box::new(snapshot()));
    let mut pane_surface = surface();
    let buffer = Buffer::with_lines([
        "trailing spaces    ",
        "   leading indent  ",
        "                   ",
    ]);
    pane_surface.frame = FrameData::from_ratatui_buffer_with_hyperlinks(&buffer, None, &[]);
    pane_surface.panes[0].rect.width = 19;
    pane_surface.panes[0].rect.height = 3;
    pane_surface.panes[0].inner_rect = pane_surface.panes[0].rect;
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("composed frame");
    state
}

#[test]
fn client_triple_click_empty_row_and_margin() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // 1. Triple click on row 2 (which is an all-space row)
    {
        let mut state = empty_row_and_margin_state();
        word_drag_mouse(&mut state, down, 2, 5);
        word_drag_mouse(&mut state, up, 2, 5);
        word_drag_mouse(&mut state, down, 2, 5);
        word_drag_mouse(&mut state, up, 2, 5);
        word_drag_mouse(&mut state, down, 2, 5);

        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((2, 0), (2, 18)),
            "triple click on an all-space empty row selects full visual row"
        );
    }

    // 2. Triple click on row 1 leading indentation (col 1 is leading whitespace)
    {
        let mut state = empty_row_and_margin_state();
        word_drag_mouse(&mut state, down, 1, 1);
        word_drag_mouse(&mut state, up, 1, 1);
        word_drag_mouse(&mut state, down, 1, 1);
        word_drag_mouse(&mut state, up, 1, 1);
        word_drag_mouse(&mut state, down, 1, 1);

        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((1, 0), (1, 18)),
            "triple click on leading indentation selects full visual row"
        );
    }

    // 3. Triple click on blank margin cell inside pane rect (row 0, col 17 trailing space)
    {
        let mut state = empty_row_and_margin_state();
        word_drag_mouse(&mut state, down, 0, 17);
        word_drag_mouse(&mut state, up, 0, 17);
        word_drag_mouse(&mut state, down, 0, 17);
        word_drag_mouse(&mut state, up, 0, 17);
        word_drag_mouse(&mut state, down, 0, 17);

        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "triple click on blank margin cell inside pane selects full visual row"
        );
    }

    // 4. Word rejection on whitespace at click 2 retains click count 2 so click 3 selects line
    {
        let mut state = empty_row_and_margin_state();
        word_drag_mouse(&mut state, down, 0, 17);
        word_drag_mouse(&mut state, up, 0, 17);

        // Click 2 requests word bounds
        let second = word_drag_mouse(&mut state, down, 0, 17);
        let req_id = word_read_id(&second.actions);
        // Reply with row text where col 17 is whitespace
        let cancel_actions = word_row_reply(&mut state, &req_id, "trailing spaces    ");
        assert!(cancel_actions.is_empty());
        assert!(
            state.selection.is_none(),
            "whitespace rejection cancels word selection"
        );
        assert_eq!(
            state.last_pane_click.as_ref().map(|c| c.count),
            Some(2),
            "whitespace rejection retains click count 2"
        );
        word_drag_mouse(&mut state, up, 0, 17);

        // Click 3 advances to count 3 and selects line
        word_drag_mouse(&mut state, down, 0, 17);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "click 3 after whitespace rejection selects full visual row"
        );
    }

    // 5. Click outside inner_rect in margin does nothing
    {
        let mut state = empty_row_and_margin_state();
        let pane = state.hits.panes[0].clone();
        let margin_click =
            state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
                kind: down,
                column: pane.inner_rect.x + pane.inner_rect.width + 5, // outside inner rect
                row: pane.inner_rect.y,
                modifiers: KeyModifiers::empty(),
            })]);
        assert!(margin_click.actions.is_empty());
        assert!(state.last_pane_click.is_none());
        assert!(state.selection.is_none());
    }
}

#[test]
fn client_line_selection_autoscroll_and_drag() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let drag = MouseEventKind::Drag(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    let mut state = word_drag_state(false);
    state.hits.panes[0].scroll = Some(crate::pane::ScrollMetrics {
        max_offset_from_bottom: 10,
        offset_from_bottom: 5,
        viewport_rows: 3,
    });
    let pane = state.hits.panes[0].clone();

    // Triple click on top row of viewport (row 0, absolute row 5)
    word_drag_mouse(&mut state, down, 0, 8);
    word_drag_mouse(&mut state, up, 0, 8);
    word_drag_mouse(&mut state, down, 0, 8);
    word_drag_mouse(&mut state, up, 0, 8);
    word_drag_mouse(&mut state, down, 0, 8);

    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((5, 0), (5, 18)),
        "line selection active on row 0"
    );

    // 1. Drag ABOVE the pane initiates autoscroll even though cursor clamps to row 0
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: drag,
        column: pane.inner_rect.x + 8,
        row: pane.inner_rect.y.saturating_sub(2), // above top of pane
        modifiers: KeyModifiers::empty(),
    })]);

    assert!(
        state.selection_autoscroll.is_some(),
        "outside-pane drag must initiate autoscroll"
    );
    assert_eq!(
        state.selection_autoscroll.as_ref().unwrap().direction,
        ClientSelectionAutoscrollDirection::Up
    );

    // Tick autoscroll
    let deadline = state.selection_autoscroll_deadline.unwrap();
    let tick = state.tick_selection_autoscroll(deadline);
    assert!(tick.repaint);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((1, 0), (5, 18)),
        "autoscroll up extends line selection upwards"
    );

    // 2. Drag BELOW the pane initiates autoscroll downwards
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: drag,
        column: pane.inner_rect.x + 8,
        row: pane.inner_rect.bottom() + 2, // below bottom of pane
        modifiers: KeyModifiers::empty(),
    })]);
    assert_eq!(
        state.selection_autoscroll.as_ref().unwrap().direction,
        ClientSelectionAutoscrollDirection::Down
    );

    // 3. Horizontal drag on selected line keeps full-row endpoints but sets dragged = true
    word_drag_mouse(&mut state, drag, 0, 15);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells().0 .1,
        0,
        "horizontal movement never narrows start column"
    );
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells().1 .1,
        18,
        "horizontal movement never narrows end column"
    );
    assert!(
        state.line_selection_gesture.as_ref().unwrap().dragged,
        "horizontal drag sets gesture.dragged = true"
    );

    // Release stops autoscroll
    word_drag_mouse(&mut state, up, 0, 15);
    assert!(state.selection_autoscroll.is_none());
}

#[test]
fn client_line_selection_history_invalidation() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // 1. Single click (count 1), release (selection is None). Focus moves away -> last_pane_click cleared
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert!(state.selection.is_none());
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        // Snapshot moves focus to pane_2
        let mut unfocused = snapshot();
        unfocused.focused_pane_id = Some("pane_2".into());
        let mut other_pane = unfocused.panes[0].clone();
        other_pane.pane_id = "pane_2".into();
        unfocused.panes.push(other_pane);
        state.set_snapshot(Box::new(unfocused));

        assert!(
            state.last_pane_click.is_none(),
            "focus change must clear last_pane_click even when selection was None"
        );

        // Next click on pane_1 starts fresh at count 1
        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // 2. Single click, release. Pane resize -> last_pane_click cleared
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        let mut resized = state.pane_surface.clone().unwrap();
        resized.surface_revision += 1;
        resized.panes[0].inner_rect.width += 5;
        state.set_pane_surface(resized);

        assert!(
            state.last_pane_click.is_none(),
            "pane resize must clear last_pane_click even when selection was None"
        );

        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // 3. Single click, release. Mouse reporting enabled -> last_pane_click cleared
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        let mut reporting = state.pane_surface.clone().unwrap();
        reporting.surface_revision += 1;
        reporting.panes[0].mouse_reporting = true;
        state.set_pane_surface(reporting);

        assert!(
            state.last_pane_click.is_none(),
            "mouse reporting enabled must clear last_pane_click"
        );
    }

    // 4. Single click, release. Type text -> last_pane_click cleared
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        state.handle_raw_events(vec![RawInputEvent::Text(crate::input::TextCommit::new(
            "a",
        ))]);
        assert!(
            state.last_pane_click.is_none(),
            "committed text must clear last_pane_click"
        );

        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // 5. Count 2 click, release. Escape key -> last_pane_click cleared (next click is count 1)
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(2));

        state.handle_raw_events(vec![RawInputEvent::Key(crate::input::TerminalKey::new(
            crossterm::event::KeyCode::Esc,
            crossterm::event::KeyModifiers::empty(),
        ))]);
        assert!(
            state.last_pane_click.is_none(),
            "Escape key must clear last_pane_click"
        );

        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(
            state.last_pane_click.as_ref().map(|c| c.count),
            Some(1),
            "next press after typing cancel is count 1, not line selection"
        );
    }
}

#[test]
fn client_line_selection_cancellation_contracts() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // 1. Focus lost cancels line selection
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.selection.is_some());

        let mut unfocused = snapshot();
        unfocused.focused_pane_id = Some("pane_other".into());
        state.set_snapshot(Box::new(unfocused));
        assert!(
            state.selection.is_none(),
            "focus loss must cancel line selection"
        );
        assert!(state.line_selection_gesture.is_none());
    }

    // 2. Typed key input during active line gesture cancels selection and gesture
    {
        let mut state = word_drag_state(true);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.line_selection_gesture.is_some());

        // Press 'x' while mouse is still down
        state.handle_raw_events(vec![RawInputEvent::Key(crate::input::TerminalKey::new(
            crossterm::event::KeyCode::Char('x'),
            crossterm::event::KeyModifiers::empty(),
        ))]);
        assert!(state.selection.is_none(), "key input must clear selection");
        assert!(
            state.line_selection_gesture.is_none(),
            "key input must clear line gesture"
        );

        // Subsequent mouse Up must not resurrect or copy
        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(
            released.actions.is_empty(),
            "subsequent mouse up must not copy after cancel"
        );
        assert!(state.selection.is_none());
    }

    // 3. Ordinary pane preserves line selection across output
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18))
        );

        let mut updated = state.pane_surface.clone().unwrap();
        updated.surface_revision += 1;
        updated.panes[0].content_revision += 1;
        state.set_pane_surface(updated);

        assert!(
            state.selection.is_some(),
            "ordinary pane preserves live line range across output"
        );
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18))
        );
    }
}

#[test]
fn client_triple_click_after_retained_ctrl_c_selects_full_row() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    let mut state = word_drag_state(false);
    // Click 1 (Down + Up)
    word_drag_mouse(&mut state, down, 0, 8);
    word_drag_mouse(&mut state, up, 0, 8);
    // Click 2 (Down + Up) -> triggers word selection
    let motion = word_drag_mouse(&mut state, down, 0, 8);
    let read_id = word_read_id(&motion.actions);
    word_row_reply(&mut state, &read_id, "alpha bravo charlie");
    word_drag_mouse(&mut state, up, 0, 8);

    assert!(state.selection.is_some());
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 6), (0, 10))
    );
    assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(2));

    // Press Ctrl+C: copies retained selection, clears selection, but PRESERVES last_pane_click
    let copy = state.handle_raw_events(vec![RawInputEvent::Key(crate::input::TerminalKey::new(
        crossterm::event::KeyCode::Char('c'),
        KeyModifiers::CONTROL,
    ))]);
    assert!(copy.actions.iter().any(|action| matches!(
        action,
        ClientShellAction::ClipboardWrite { .. } | ClientShellAction::Endpoint { .. }
    )));
    assert!(state.selection.is_none());
    assert_eq!(
        state.last_pane_click.as_ref().map(|c| c.count),
        Some(2),
        "Ctrl+C copy must preserve stationary count2 click history"
    );

    // Next Down (click 3) at the same position -> selects whole row!
    word_drag_mouse(&mut state, down, 0, 8);
    assert_eq!(
        state.last_pane_click.as_ref().map(|c| c.count),
        Some(3),
        "next click after Ctrl+C advances to count 3"
    );
    assert!(state.selection.is_some());
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 0), (0, 18)),
        "count 3 selects full visual row"
    );
}

#[test]
fn client_line_selection_horizontal_drag_discrimination() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let drag = MouseEventKind::Drag(MouseButton::Left);
    let moved = MouseEventKind::Moved;
    let up = MouseEventKind::Up(MouseButton::Left);

    // Case A: same-cell Drag and ordinary Moved remain stationary
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);

        assert!(state.line_selection_gesture.is_some());
        assert!(!state.line_selection_gesture.as_ref().unwrap().dragged);
        assert!(state.last_pane_click.is_some());

        // Same-cell Drag (col 8, row 0)
        word_drag_mouse(&mut state, drag, 0, 8);
        assert!(
            !state.line_selection_gesture.as_ref().unwrap().dragged,
            "same-cell drag without movement must remain stationary"
        );
        assert!(state.last_pane_click.is_some());

        // Ordinary Moved (col 9, row 0) without button down
        word_drag_mouse(&mut state, moved, 0, 9);
        assert!(
            !state.line_selection_gesture.as_ref().unwrap().dragged,
            "ordinary Moved must remain stationary"
        );
        assert!(state.last_pane_click.is_some());
    }

    // Case B: fresh line gesture -> 1-column horizontal-only Drag marks dragged and resets history
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);

        assert!(!state.line_selection_gesture.as_ref().unwrap().dragged);
        assert!(state.last_pane_click.is_some());

        // Drag by 1 column (col 9, row 0)
        word_drag_mouse(&mut state, drag, 0, 9);
        assert!(
            state.line_selection_gesture.as_ref().unwrap().dragged,
            "one-column horizontal Drag marks dragged = true"
        );
        assert!(
            state.last_pane_click.is_none(),
            "one-column horizontal Drag resets click history"
        );
        assert_eq!(
            state.selection.as_ref().unwrap().ordered_cells(),
            ((0, 0), (0, 18)),
            "horizontal drag preserves full-row endpoints"
        );
    }
}

#[test]
fn client_line_selection_focus_lag_and_confirmation() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    let mut state = word_drag_state(true);

    // Initial snapshot has focused_pane_id: Some("old_pane") (still-old focus before pane_1 click)
    let mut initial_snap = snapshot();
    let mut old_pane = initial_snap.panes[0].clone();
    old_pane.pane_id = "old_pane".into();
    initial_snap.panes.push(old_pane);
    initial_snap.focused_pane_id = Some("old_pane".into());
    state.set_snapshot(Box::new(initial_snap));

    // Triple click on pane_1 (row 0, col 8), holding third press
    word_drag_mouse(&mut state, down, 0, 8);
    word_drag_mouse(&mut state, up, 0, 8);
    word_drag_mouse(&mut state, down, 0, 8);
    word_drag_mouse(&mut state, up, 0, 8);
    word_drag_mouse(&mut state, down, 0, 8);

    assert!(state.line_selection_gesture.is_some());
    assert!(
        !state
            .line_selection_gesture
            .as_ref()
            .unwrap()
            .focus_confirmed
    );

    // 1a. Snapshot with still-old focus ("old_pane") arrives -> line selection survives!
    let mut still_old_snap = snapshot();
    let mut old_pane = still_old_snap.panes[0].clone();
    old_pane.pane_id = "old_pane".into();
    still_old_snap.panes.push(old_pane);
    still_old_snap.focused_pane_id = Some("old_pane".into());
    state.set_snapshot(Box::new(still_old_snap));
    assert!(
        state.line_selection_gesture.is_some(),
        "line selection must survive still-old pending focus snapshot before confirmation"
    );
    assert!(
        !state
            .line_selection_gesture
            .as_ref()
            .unwrap()
            .focus_confirmed
    );
    assert!(state.selection.is_some());

    // 1b. Snapshot with focused_pane_id: None arrives -> line selection survives!
    let mut intermediate_snap = snapshot();
    intermediate_snap.focused_pane_id = None;
    state.set_snapshot(Box::new(intermediate_snap));
    assert!(
        state.line_selection_gesture.is_some(),
        "line selection must survive focus lag when focused_pane_id is None"
    );
    assert!(state.selection.is_some());

    // 2. Snapshot arrives confirming focus on pane_1
    let mut confirmed_snap = snapshot();
    confirmed_snap.focused_pane_id = Some("pane_1".into());
    state.set_snapshot(Box::new(confirmed_snap));
    assert!(
        state
            .line_selection_gesture
            .as_ref()
            .unwrap()
            .focus_confirmed,
        "focus is now confirmed on pane_1"
    );
    assert!(state.selection.is_some());

    // 3. Focus moves away to pane_2 -> cancels line selection
    let mut other_snap = snapshot();
    other_snap.focused_pane_id = Some("pane_2".into());
    let mut other_pane = other_snap.panes[0].clone();
    other_pane.pane_id = "pane_2".into();
    other_snap.panes.push(other_pane);
    state.set_snapshot(Box::new(other_snap));

    assert!(
        state.selection.is_none(),
        "focus moving away cancels line selection"
    );
    assert!(state.line_selection_gesture.is_none());
    assert!(state.last_pane_click.is_none());

    // 4. Later Up must not copy
    let released = word_drag_mouse(&mut state, up, 0, 8);
    assert!(
        released.actions.is_empty(),
        "mouse Up after focus cancellation must not copy"
    );
}

#[test]
fn client_line_selection_zero_geometry_pane_is_no_op() {
    let mut state = word_drag_state(false);

    // Case 1: width 0, positive height
    {
        let mut hit = state.hits.panes[0].clone();
        hit.inner_rect.width = 0;
        hit.inner_rect.height = 3;

        let mut outcome = ClientShellInput::default();
        state.start_line_selection(&hit, 0, 0, &mut outcome);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(!outcome.repaint);
    }

    // Case 2: positive width, height 0
    {
        let mut hit = state.hits.panes[0].clone();
        hit.inner_rect.width = 19;
        hit.inner_rect.height = 0;

        let mut outcome = ClientShellInput::default();
        state.start_line_selection(&hit, 0, 0, &mut outcome);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(!outcome.repaint);
    }

    // Case 3: width 0, height 0
    {
        let mut hit = state.hits.panes[0].clone();
        hit.inner_rect.width = 0;
        hit.inner_rect.height = 0;

        let mut outcome = ClientShellInput::default();
        state.start_line_selection(&hit, 0, 0, &mut outcome);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(!outcome.repaint);
    }
}

#[test]
fn client_line_selection_held_invalidation_branches() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);

    // A. Pane close while held
    {
        let mut state = word_drag_state(true);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.line_selection_gesture.is_some());

        let mut closed_snap = snapshot();
        closed_snap.panes.clear();
        state.set_snapshot(Box::new(closed_snap));
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());

        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(released.actions.is_empty());

        // Next Down starts at count 1
        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // B. Child mouse reporting enabled while held
    {
        let mut state = word_drag_state(true);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.line_selection_gesture.is_some());

        let mut reporting = state.pane_surface.clone().unwrap();
        reporting.surface_revision += 1;
        reporting.panes[0].mouse_reporting = true;
        state.set_pane_surface(reporting);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(state.last_pane_click.is_none());

        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(released.actions.is_empty());

        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // C. Popup appears while held (preserving 19x3 pane geometry)
    {
        let mut state = word_drag_state(true);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.line_selection_gesture.is_some());

        let mut popup_surface = state.pane_surface.clone().unwrap();
        popup_surface.surface_revision += 1;
        popup_surface.popup = surface_with_popup().popup;
        state.set_pane_surface(popup_surface);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(state.last_pane_click.is_none());

        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(released.actions.is_empty());
    }

    // D. Endpoint disconnect while held
    {
        let mut state = word_drag_state(true);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        word_drag_mouse(&mut state, down, 0, 8);
        assert!(state.line_selection_gesture.is_some());

        // Inactive endpoint disconnect does NOT cancel active line selection
        let unrelated_endpoint = crate::client::endpoint::ClientEndpointId::Ssh(
            crate::client::endpoint::ProfileId::parse("0123456789abcdef0123456789abcdef").unwrap(),
        );
        state.mark_endpoint_disconnected(&unrelated_endpoint);
        assert!(
            state.line_selection_gesture.is_some(),
            "unrelated endpoint disconnect must not cancel active line selection"
        );

        // Active endpoint disconnect cancels line selection and click history
        state.mark_endpoint_disconnected(&ClientEndpointId::Local);
        assert!(state.selection.is_none());
        assert!(state.line_selection_gesture.is_none());
        assert!(state.last_pane_click.is_none());

        let released = word_drag_mouse(&mut state, up, 0, 8);
        assert!(released.actions.is_empty());
    }
}

#[test]
fn client_active_disconnect_resets_click_history_and_preserves_reconnect_selection() {
    let down = MouseEventKind::Down(MouseButton::Left);
    let up = MouseEventKind::Up(MouseButton::Left);
    let unrelated_endpoint = crate::client::endpoint::ClientEndpointId::Ssh(
        crate::client::endpoint::ProfileId::parse("0123456789abcdef0123456789abcdef").unwrap(),
    );

    // 1. Stationary count 1 disconnect -> reconnect -> next Down starts at count 1
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        // Unrelated endpoint disconnect preserves click history
        state.mark_endpoint_disconnected(&unrelated_endpoint);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));

        // Active endpoint disconnect resets click history
        state.mark_endpoint_disconnected(&ClientEndpointId::Local);
        assert!(state.last_pane_click.is_none());

        // Reconnect endpoint
        state.set_endpoint_status(
            &ClientEndpointId::Local,
            crate::client::endpoint::ClientEndpointStatus::Online,
        );

        // Next Down starts at count 1 (not count 2)
        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }

    // 2. Stationary count 2 disconnect -> reconnect -> next Down starts at count 1
    {
        let mut state = word_drag_state(false);
        word_drag_mouse(&mut state, down, 0, 8);
        word_drag_mouse(&mut state, up, 0, 8);
        let motion = word_drag_mouse(&mut state, down, 0, 8);
        let read_id = word_read_id(&motion.actions);
        word_row_reply(&mut state, &read_id, "alpha bravo charlie");
        word_drag_mouse(&mut state, up, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(2));
        assert!(state.selection.is_some(), "count 2 resolved word selection");

        // Active endpoint disconnect resets click history but preserves retained word selection
        state.mark_endpoint_disconnected(&ClientEndpointId::Local);
        assert!(state.last_pane_click.is_none());
        assert!(
            state.selection.is_some(),
            "reconnect word selection is preserved across disconnect"
        );

        // Reconnect endpoint
        state.set_endpoint_status(
            &ClientEndpointId::Local,
            crate::client::endpoint::ClientEndpointStatus::Online,
        );

        // Next Down starts at count 1 (not count 3)
        word_drag_mouse(&mut state, down, 0, 8);
        assert_eq!(state.last_pane_click.as_ref().map(|c| c.count), Some(1));
    }
}

fn word_drag_state(copy_on_select: bool) -> ClientShellState {
    let mut config = Config::default();
    config.ui.copy_on_select = copy_on_select;
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&config));
    state.set_snapshot(Box::new(snapshot()));
    let mut pane_surface = surface();
    let buffer = Buffer::with_lines([
        "alpha bravo charlie",
        "delta echo foxtrot ",
        "golf hotel india   ",
    ]);
    pane_surface.frame = FrameData::from_ratatui_buffer_with_hyperlinks(&buffer, None, &[]);
    pane_surface.panes[0].rect.width = 19;
    pane_surface.panes[0].rect.height = 3;
    pane_surface.panes[0].inner_rect = pane_surface.panes[0].rect;
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("composed frame");
    state
}

fn word_drag_mouse(
    state: &mut ClientShellState,
    kind: MouseEventKind,
    row: u16,
    col: u16,
) -> ClientShellInput {
    let pane = state.hits.panes[0].clone();
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind,
        column: pane.inner_rect.x + col,
        row: pane.inner_rect.y + row,
        modifiers: KeyModifiers::empty(),
    })])
}

fn word_read_id(actions: &[ClientShellAction]) -> String {
    actions
        .iter()
        .find_map(|action| match action {
            ClientShellAction::Endpoint { request, .. }
                if matches!(
                    request.method,
                    crate::api::schema::Method::PaneSelectionRead(_)
                ) =>
            {
                Some(request.id.clone())
            }
            _ => None,
        })
        .expect("selection read")
}

fn word_row_reply(state: &mut ClientShellState, id: &str, text: &str) -> Vec<ClientShellAction> {
    state
        .handle_endpoint_result(
            "boot-1",
            id,
            Ok(crate::api::schema::ResponseResult::PaneSelection {
                pane_id: "pane_1".into(),
                text: text.into(),
            }),
        )
        .1
}

fn start_word_drag(state: &mut ClientShellState) -> String {
    word_drag_mouse(state, MouseEventKind::Down(MouseButton::Left), 0, 8);
    word_drag_mouse(state, MouseEventKind::Up(MouseButton::Left), 0, 8);
    assert!(state.selection.is_none(), "plain clicks must not select");
    let second = word_drag_mouse(state, MouseEventKind::Down(MouseButton::Left), 0, 8);
    assert!(second.actions.iter().any(|action| matches!(action, ClientShellAction::Endpoint { request, .. }
        if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
            if params.anchor.col == 0 && params.cursor.col == state.hits.panes[0].inner_rect.width - 1))));
    word_read_id(&second.actions)
}

#[test]
fn double_click_drag_selects_whole_words_in_both_directions() {
    let mut state = word_drag_state(false);
    let initial = start_word_drag(&mut state);
    word_row_reply(&mut state, &initial, "alpha bravo charlie");
    for (col, expected) in [
        (14, ((0, 6), (0, 18))),
        (2, ((0, 0), (0, 10))),
        (8, ((0, 6), (0, 10))),
        (11, ((0, 6), (0, 11))),
        (16, ((0, 6), (0, 18))),
    ] {
        let motion = word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 0, col);
        assert!(
            motion.actions.is_empty(),
            "reuse the row while dragging within it"
        );
        assert_eq!(state.selection.as_ref().unwrap().ordered_cells(), expected);
    }
    assert!(
        word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 16)
            .actions
            .is_empty()
    );
    assert!(state.selection.as_ref().unwrap().is_finalized());
}

#[test]
fn double_click_drag_waits_for_latest_row_before_copying() {
    for release_before_anchor in [false, true] {
        let mut state = word_drag_state(true);
        let initial = start_word_drag(&mut state);
        if !release_before_anchor {
            assert!(word_row_reply(&mut state, &initial, "alpha bravo charlie").is_empty());
        }
        let first_motion =
            word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 1, 8);
        for col in [1, 3, 7] {
            assert!(
                word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 2, col)
                    .actions
                    .is_empty()
            );
        }
        assert!(
            word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 2, 7)
                .actions
                .is_empty()
        );
        let final_read = if release_before_anchor {
            word_row_reply(&mut state, &initial, "alpha bravo charlie")
        } else {
            word_row_reply(
                &mut state,
                &word_read_id(&first_motion.actions),
                "delta echo foxtrot",
            )
        };
        assert!(
            matches!(&final_read[..], [ClientShellAction::Endpoint { request, .. }]
            if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                if params.anchor.row == 2 && params.cursor.row == 2))
        );
        let copy = word_row_reply(&mut state, &word_read_id(&final_read), "golf hotel india");
        assert!(
            matches!(&copy[..], [ClientShellAction::Endpoint { request, .. }]
            if matches!(&request.method, crate::api::schema::Method::PaneSelectionRead(params)
                if params.anchor == crate::api::schema::PaneTextPoint { row: 0, col: 6 }
                    && params.cursor == crate::api::schema::PaneTextPoint { row: 2, col: 9 }))
        );
        let copied = word_row_reply(
            &mut state,
            &word_read_id(&copy),
            "bravo charlie\ndelta echo foxtrot\ngolf hotel",
        );
        assert!(
            matches!(&copied[..], [ClientShellAction::ClipboardWrite(bytes)]
            if bytes == b"bravo charlie\ndelta echo foxtrot\ngolf hotel")
        );
    }
}

#[test]
fn double_click_drag_ignores_row_reply_after_typing_or_new_click() {
    for typing in [false, true] {
        let mut state = word_drag_state(false);
        let initial = start_word_drag(&mut state);
        word_row_reply(&mut state, &initial, "alpha bravo charlie");
        let drag = word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 1, 8);
        let row_id = word_read_id(&drag.actions);
        if typing {
            state.handle_input_bytes(b"x");
        } else {
            word_drag_mouse(&mut state, MouseEventKind::Down(MouseButton::Left), 0, 0);
            word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 0);
        }
        assert!(word_row_reply(&mut state, &row_id, "delta echo foxtrot").is_empty());
        assert!(state.selection.is_none());
    }
}

#[test]
fn double_click_drag_survives_focus_lag_after_anchor_reply() {
    let mut state = word_drag_state(true);
    let initial = start_word_drag(&mut state);
    word_row_reply(&mut state, &initial, "alpha bravo charlie");
    let mut lagging = snapshot();
    lagging.focused_pane_id = None;
    lagging.panes[0].focused = false;
    state.set_snapshot(Box::new(lagging));
    assert!(state.selection.is_some());
    word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 0, 14);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((0, 6), (0, 18))
    );
    let released = word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 14);
    assert_eq!(released.actions.len(), 1);
}

#[test]
fn double_click_drag_invalidates_cached_boundaries_outside_selected_cells() {
    for copy_on_select in [false, true] {
        let mut state = word_drag_state(copy_on_select);
        let initial = start_word_drag(&mut state);
        word_row_reply(&mut state, &initial, "alpha bravo charlie");
        let mut changed = state.pane_surface.as_ref().unwrap().clone();
        changed.surface_revision += 1;
        changed.panes[0].content_revision += 2;
        changed.frame.cells[14].symbol = " ".into();
        state.set_pane_surface(changed);
        assert!(
            state.selection.is_none(),
            "unchanged selected cells do not validate cached boundaries outside the selection"
        );
        assert!(
            word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 0, 14)
                .actions
                .is_empty()
        );
        assert!(
            word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 14)
                .actions
                .is_empty()
        );
        assert!(state.selection.is_none());
    }
}

#[test]
fn reconnect_word_selection_tracks_content_changes() {
    for content_changed in [false, true] {
        let mut state = word_drag_state(true);
        let initial = start_word_drag(&mut state);
        word_row_reply(&mut state, &initial, "alpha bravo charlie");
        let mut next_surface = state.pane_surface.as_ref().unwrap().clone();
        if content_changed {
            next_surface.panes[0].content_revision += 2;
            next_surface.frame.cells[14].symbol = " ".into();
        }
        let endpoint_id = state.active_endpoint_id.clone();
        let snapshot = state.snapshot.as_ref().unwrap().clone();
        state.mark_endpoint_disconnected(&endpoint_id);
        state.cache_endpoint_snapshot_inactive_for_generation(&endpoint_id, 1, snapshot);
        state.set_endpoint_status(
            &endpoint_id,
            crate::client::endpoint::ClientEndpointStatus::Online,
        );
        assert!(state.activate_endpoint_projection(&endpoint_id));
        state.set_pane_surface(next_surface);

        assert_eq!(state.selection.is_some(), !content_changed);
        assert_eq!(state.word_selection_gesture.is_some(), !content_changed);
    }
}

#[test]
fn double_click_release_ignores_reply_after_focus_or_content_changes() {
    for focus_changed in [false, true] {
        let mut state = word_drag_state(true);
        let initial = start_word_drag(&mut state);
        word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 8);
        if focus_changed {
            let mut lagging = snapshot();
            lagging.focused_pane_id = None;
            lagging.panes[0].focused = false;
            state.set_snapshot(Box::new(lagging));
            let mut unfocused = snapshot();
            unfocused.focused_pane_id = Some("pane_2".into());
            unfocused.panes[0].focused = false;
            let mut other = unfocused.panes[0].clone();
            other.pane_id = "pane_2".into();
            other.focused = true;
            unfocused.panes.push(other);
            state.set_snapshot(Box::new(unfocused));
        } else {
            let mut changed = state.pane_surface.as_ref().unwrap().clone();
            changed.surface_revision += 1;
            changed.panes[0].content_revision += 2;
            state.set_pane_surface(changed);
        }
        assert!(
            word_row_reply(&mut state, &initial, "alpha bravo charlie").is_empty(),
            "a stale released gesture must not copy"
        );
        assert!(state.selection.is_none());
    }
}

#[test]
fn double_click_drag_resize_cancels_pending_word_lookup() {
    for anchor_ready in [false, true] {
        let mut state = word_drag_state(true);
        let initial = start_word_drag(&mut state);
        let pending = if anchor_ready {
            word_row_reply(&mut state, &initial, "alpha bravo charlie");
            let motion = word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 1, 8);
            word_read_id(&motion.actions)
        } else {
            initial
        };
        word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 1, 8);
        let mut resized = state.pane_surface.as_ref().unwrap().clone();
        resized.surface_revision += 1;
        resized.panes[0].rect.width += 5;
        resized.panes[0].inner_rect.width += 5;
        state.set_pane_surface(resized);
        assert!(word_row_reply(&mut state, &pending, "alpha bravo charlie extra").is_empty());
        assert!(
            state.selection.is_none(),
            "a late reply must not restore a resized selection"
        );
        assert!(state.selection_autoscroll.is_none());
    }
}

#[test]
fn double_click_drag_autoscroll_keeps_absolute_word_anchor() {
    let mut state = word_drag_state(false);
    state.hits.panes[0].scroll = Some(crate::pane::ScrollMetrics {
        max_offset_from_bottom: 10,
        offset_from_bottom: 5,
        viewport_rows: 3,
    });
    let initial = start_word_drag(&mut state);
    word_row_reply(&mut state, &initial, "alpha bravo charlie");
    word_drag_mouse(&mut state, MouseEventKind::Drag(MouseButton::Left), 0, 14);
    let tick = state.tick_selection_autoscroll(state.selection_autoscroll_deadline.unwrap());
    word_row_reply(
        &mut state,
        &word_read_id(&tick.actions),
        "delta echo foxtrot",
    );
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((4, 11), (5, 10))
    );
    word_drag_mouse(&mut state, MouseEventKind::Up(MouseButton::Left), 0, 14);
    assert!(state.selection.as_ref().unwrap().is_finalized());
    assert!(state.selection_autoscroll.is_none());
}

#[test]
fn pane_content_updates_preserve_live_ranges_until_geometry_or_screen_changes() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    let surface_at = |surface_revision, content_revision, alternate_screen_active| {
        let mut pane_surface = surface();
        pane_surface.surface_revision = surface_revision;
        pane_surface.panes[0].content_revision = content_revision;
        pane_surface.panes[0].scroll = Some(crate::protocol::PaneSurfaceScrollMetrics {
            offset_from_bottom: 0,
            max_offset_from_bottom: 11,
            viewport_rows: 2,
        });
        pane_surface.panes[0].alternate_screen_active = alternate_screen_active;
        pane_surface
    };
    state.set_pane_surface(surface_at(1, 0, true));
    state.compose(106, 20).expect("composed frame");
    let pane = state.hits.panes[0].clone();
    let mouse = |kind, column, row| {
        RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind,
            column,
            row,
            modifiers: KeyModifiers::empty(),
        })
    };

    state.handle_raw_events(vec![mouse(
        MouseEventKind::Down(MouseButton::Left),
        pane.inner_rect.x,
        pane.inner_rect.y + 1,
    )]);
    let mut updated_surface = surface_at(2, 2, true);
    updated_surface.frame.cells[0].symbol = "W".into();
    state.set_pane_surface(updated_surface);
    state.compose(106, 20).expect("updated frame");

    let drag = state.handle_raw_events(vec![mouse(
        MouseEventKind::Drag(MouseButton::Left),
        pane.inner_rect.x + 1,
        pane.inner_rect.y + 1,
    )]);

    assert!(drag.repaint || state.selection_repaint_deadline.is_some());
    let selection = state.selection.as_ref().expect("visible selection");
    assert!(selection.is_visible());
    assert_eq!(selection.ordered_cells(), ((12, 0), (12, 1)));

    let mut replaced_surface = surface_at(3, 4, true);
    replaced_surface.frame.cells[4].symbol = "X".into();
    state.set_pane_surface(replaced_surface);
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((12, 0), (12, 1))
    );

    // The selected row can leave the viewport during a drag. A later patch,
    // including an in-flight content revision, must keep that absolute range.
    let mut scrolled = surface_at(4, 5, true);
    scrolled.panes[0]
        .scroll
        .as_mut()
        .unwrap()
        .offset_from_bottom = 2;
    assert!(matches!(
        state.apply_pane_surface_patch(crate::protocol::PaneSurfacePatch {
            boot_id: scrolled.boot_id,
            projection_revision: scrolled.projection_revision,
            base_surface_revision: 3,
            surface_revision: 4,
            panes: scrolled.panes,
            rows: vec![],
            cursor: scrolled.frame.cursor,
        }),
        super::super::surface_patch::ClientPaneSurfacePatchOutcome::Applied(_)
    ));
    assert!(state.selection.as_ref().unwrap().is_in_progress());
    assert_eq!(
        state.selection.as_ref().unwrap().ordered_cells(),
        ((12, 0), (12, 1))
    );

    for (surface_revision, content_revision, width, alternate_screen_active) in
        [(5, 6, 4, false), (6, 8, 3, false)]
    {
        state.selection = Some(crate::selection::Selection::absolute_anchor(
            "pane_1".to_owned(),
            (12, 0),
        ));
        let mut changed_surface =
            surface_at(surface_revision, content_revision, alternate_screen_active);
        changed_surface.panes[0].inner_rect.width = width;
        changed_surface.panes[0].alternate_screen_active = alternate_screen_active;
        state.set_pane_surface(changed_surface);
        assert!(state.selection.is_none());
    }
}

#[test]
fn pane_mouse_input_keeps_stable_target_and_endpoint_encoding() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    let mut pane_surface = surface();
    pane_surface.panes[0].mouse_reporting = true;
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("composed frame");
    let pane = state.hits.panes[0].clone();

    let click = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: pane.inner_rect.x + 2,
        row: pane.inner_rect.y + 1,
        modifiers: KeyModifiers::ALT,
    })]);
    let [ClientMessage::ClientShellPaneInput { pane_id, events }] = &click.requests[..] else {
        panic!("pane application click should use targeted canonical input");
    };
    assert_eq!(pane_id, "pane_1");
    assert!(matches!(
        &events[..],
        [ClientPaneInputEvent::Mouse {
            kind: crate::protocol::ClientMouseKind::Down(
                crate::protocol::ClientMouseButton::Left
            ),
            position: ClientMousePosition::Cell { column: 2, row: 1 },
            modifiers,
            ..
        }] if *modifiers == KeyModifiers::ALT.bits()
    ));
    let moved = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Moved,
        column: 0,
        row: 0,
        modifiers: KeyModifiers::ALT,
    })]);
    assert!(moved.requests.is_empty());
    assert!(state.pane_mouse_gesture.is_some());
    state.hits.panes.clear();
    let release =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: 0,
            row: 0,
            modifiers: KeyModifiers::ALT,
        })]);
    assert!(matches!(
        &release.requests[..],
        [ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(
                    &events[..],
                    [ClientPaneInputEvent::Mouse {
                        kind: crate::protocol::ClientMouseKind::Up(
                            crate::protocol::ClientMouseButton::Left
                        ),
                        ..
                    }]
                )
    ));
    assert!(state.pane_mouse_gesture.is_none());
}

#[test]
fn pane_pixel_mouse_preserves_pane_relative_pixel_coordinates() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    let mut pane_surface = surface();
    pane_surface.panes[0].mouse_reporting = true;
    pane_surface.panes[0].sgr_pixel_mouse = true;
    pane_surface.panes[0].pixel_width = 39;
    pane_surface.panes[0].pixel_height = 38;
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("composed frame");
    let pane = state.hits.panes[0].clone();
    let geometry =
        crate::input::mouse::HostGeometry::new(106, 20, 1060, 400).expect("host geometry");
    let x = u32::from(pane.inner_rect.x) * 10 + 21;
    let y = u32::from(pane.inner_rect.y) * 20 + 21;
    let report = format!("\x1b[<0;{x};{y}M");

    let outcome = state.handle_pixel_mouse(report.as_bytes(), geometry);
    assert!(matches!(
        &outcome.requests[..],
        [ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(
                    &events[..],
                    [ClientPaneInputEvent::Mouse {
                        kind: crate::protocol::ClientMouseKind::Down(
                            crate::protocol::ClientMouseButton::Left
                        ),
                        position: ClientMousePosition::Pixels { x: 20, y: 20, .. },
                        ..
                    }]
                )
    ));

    let lost = state.handle_raw_events(vec![RawInputEvent::OuterFocusLost]);
    assert!(matches!(
        &lost.requests[..],
        [
            ClientMessage::ClientShellPaneInput { pane_id, events },
            ClientMessage::ClientShellFocus { focused: false }
        ] if pane_id == "pane_1" && matches!(
            &events[..],
            [ClientPaneInputEvent::Mouse {
                kind: crate::protocol::ClientMouseKind::Up(
                    crate::protocol::ClientMouseButton::Left
                ),
                position: ClientMousePosition::Pixels { x: 20, y: 20, .. },
                ..
            }]
        )
    ));
}

#[test]
fn pane_owned_right_click_forwards_the_complete_gesture() {
    let mut snapshot = snapshot();
    snapshot.panes[0].right_click_passthrough = true;
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot));
    let mut pane_surface = surface();
    pane_surface.panes[0].mouse_reporting = true;
    state.set_pane_surface(pane_surface);
    state.compose(106, 20).expect("composed frame");
    let pane = state.hits.panes[0].clone();

    let down = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: pane.inner_rect.x + 1,
        row: pane.inner_rect.y,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        &down.requests[..],
        [ClientMessage::ClientShellPaneInput { pane_id, .. }] if pane_id == "pane_1"
    ));
    assert!(state.overlay.is_none());
    assert!(state.pane_mouse_gesture.is_some());

    let up = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Right),
        column: 0,
        row: 0,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        &up.requests[..],
        [ClientMessage::ClientShellPaneInput { pane_id, events }]
            if pane_id == "pane_1"
                && matches!(
                    &events[..],
                    [ClientPaneInputEvent::Mouse {
                        kind: crate::protocol::ClientMouseKind::Up(
                            crate::protocol::ClientMouseButton::Right
                        ),
                        ..
                    }]
                )
    ));
    assert!(state.pane_mouse_gesture.is_none());
}

#[test]
fn tab_click_waits_for_release_and_drag_reorders_by_stable_id() {
    let mut projected = snapshot();
    for index in 2..=3 {
        let mut tab = projected.tabs[0].clone();
        tab.tab_id = format!("tab_{index}");
        tab.number = index;
        tab.label = index.to_string();
        tab.focused = false;
        projected.tabs.push(tab);
    }
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(projected));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("three tabs");
    let first = state.hits.tabs[0].0;
    let third = state.hits.tabs[2].0;

    let down = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: first.x + 1,
        row: first.y,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(down.actions.is_empty());
    let drag = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: third.right().saturating_sub(1),
        row: third.y,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(drag.repaint);
    assert!(matches!(
        state.chrome_drag,
        Some(ClientChromeDrag::Tab {
            ref tab_id,
            insert_index: Some(3),
            ..
        }) if tab_id == "tab_1"
    ));
    let frame = state.compose(106, 20).expect("tab drop indicator");
    assert!(frame
        .cells
        .iter()
        .take(frame.width as usize)
        .any(|cell| cell.symbol == "│"));

    let release =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: third.right().saturating_sub(1),
            row: third.y,
            modifiers: KeyModifiers::empty(),
        })]);
    let [ClientShellAction::Endpoint { request, .. }] = &release.actions[..] else {
        panic!("tab drag should use endpoint API");
    };
    assert!(matches!(
        &request.method,
        crate::api::schema::Method::TabMove(params)
            if params.tab_id == "tab_1" && params.insert_index == 3
    ));

    state.compose(106, 20).expect("tabs after drag");
    let second = state.hits.tabs[1].0;
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: second.x + 1,
        row: second.y,
        modifiers: KeyModifiers::empty(),
    })]);
    let click = state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Up(MouseButton::Left),
        column: second.x + 1,
        row: second.y,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        &click.actions[0],
        ClientShellAction::Endpoint { request, .. }
            if matches!(&request.method, crate::api::schema::Method::TabFocus(target) if target.tab_id == "tab_2")
    ));
}

#[test]
fn tab_drag_clears_its_drop_target_after_leaving_the_tab_row() {
    let mut projected = snapshot();
    for index in 2..=3 {
        let mut tab = projected.tabs[0].clone();
        tab.tab_id = format!("tab_{index}");
        tab.number = index;
        tab.label = index.to_string();
        tab.focused = false;
        projected.tabs.push(tab);
    }
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(projected));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("three tabs");
    let first = state.hits.tabs[0].0;
    let third = state.hits.tabs[2].0;
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: first.x + 1,
        row: first.y,
        modifiers: KeyModifiers::empty(),
    })]);
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: third.x,
        row: third.y,
        modifiers: KeyModifiers::empty(),
    })]);
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Drag(MouseButton::Left),
        column: third.x,
        row: third.y + 1,
        modifiers: KeyModifiers::empty(),
    })]);
    assert!(matches!(
        state.chrome_drag,
        Some(ClientChromeDrag::Tab {
            insert_index: None,
            ..
        })
    ));
    let release =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Up(MouseButton::Left),
            column: third.x,
            row: third.y + 1,
            modifiers: KeyModifiers::empty(),
        })]);
    assert!(release.actions.is_empty());
}

#[test]
fn tab_wheel_switches_tabs_without_changing_overflow_scroll() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("tab bar");
    let tab = state.hits.tabs[0].0;

    let outcome =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::ScrollDown,
            column: tab.x,
            row: tab.y,
            modifiers: KeyModifiers::empty(),
        })]);
    assert!(matches!(
        &outcome.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(
                &request.method,
                crate::api::schema::Method::TabFocus(target) if target.tab_id == "tab_1"
            )
    ));
    assert_eq!(state.tab_scroll, 0);
    state.compose(106, 20).expect("tab bar after wheel");
    assert!(state.hits.tabs.iter().any(|(_, tab_id)| tab_id == "tab_1"));
}

#[test]
fn context_menu_keyboard_and_outside_click_are_client_owned() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state.compose(106, 20).expect("composed frame");
    let tab = state.hits.tabs[0].0;
    state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Right),
        column: tab.x + 1,
        row: tab.y,
        modifiers: KeyModifiers::empty(),
    })]);
    state.compose(106, 20).expect("tab context menu");
    let moved = state.handle_input_bytes(b"\x1b[B");
    assert!(moved.repaint);
    assert!(matches!(
        state.overlay,
        Some(ClientShellOverlay::ContextMenu(ClientContextMenuOverlay {
            highlighted: 1,
            ..
        }))
    ));
    let text = state.handle_raw_events(vec![RawInputEvent::Text(crate::input::TextCommit::new(
        "not pane input",
    ))]);
    assert!(text.requests.is_empty());
    let paste = state.handle_raw_events(vec![RawInputEvent::Paste("not pane input".into())]);
    assert!(paste.requests.is_empty());
    let outside =
        state.handle_raw_events(vec![RawInputEvent::Mouse(crossterm::event::MouseEvent {
            kind: MouseEventKind::Down(MouseButton::Left),
            column: 105,
            row: 19,
            modifiers: KeyModifiers::empty(),
        })]);
    assert!(outside.repaint);
    assert!(state.overlay.is_none());
}
