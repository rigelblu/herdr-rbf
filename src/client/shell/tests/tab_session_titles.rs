use super::*;

fn titled_agent(tab: &ClientShellTab, pane_id: &str, title: Option<&str>) -> ClientShellAgent {
    ClientShellAgent {
        pane_id: pane_id.into(),
        workspace_id: tab.workspace_id.clone(),
        tab_id: tab.tab_id.clone(),
        name: Some("codex".into()),
        display_agent: None,
        agent: Some("codex".into()),
        title: None,
        terminal_title: title.map(|title| format!("⠋ {title}")),
        terminal_title_stripped: title.map(str::to_owned),
        agent_status: AgentStatus::Working,
        state_change_seq: 0,
        state_labels: Vec::new(),
        tokens: Vec::new(),
        focused: false,
    }
}

fn tab_strip(state: &mut ClientShellState, width: u16) -> String {
    let frame = state.compose(width, 20).expect("composed frame");
    let rect = state.hits.tabs.first().expect("tab hit target").0;
    let row_start = rect.y as usize * frame.width as usize;
    let row = &frame.cells[row_start..row_start + frame.width as usize];
    let mut text = String::new();
    let mut column = 0;
    while column < row.len() {
        let symbol = row[column].symbol.as_str();
        text.push_str(symbol);
        column += UnicodeWidthStr::width(symbol).max(1);
    }
    text
}

fn state_with(projected: ClientShellSnapshot) -> ClientShellState {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(projected));
    state.set_pane_surface(surface());
    state
}

#[test]
fn hrdr28_tab_title_updates_without_renaming_the_saved_label() {
    let mut projected = snapshot();
    projected.tabs[0].label = "review".into();
    projected.tabs[0].custom_label = true;
    projected.agents = vec![titled_agent(&projected.tabs[0], "pane_1", Some("before"))];
    let mut state = state_with(projected.clone());
    assert!(tab_strip(&mut state, 120).contains("review · before"));
    assert_eq!(state.snapshot.as_ref().unwrap().tabs[0].label, "review");
    projected.agents[0].terminal_title_stripped = Some("after".into());
    state.set_snapshot(Box::new(projected));
    let row = tab_strip(&mut state, 120);
    assert!(row.contains("review · after"), "{row}");
    assert!(!row.contains("before"));
    assert_eq!(state.snapshot.as_ref().unwrap().tabs[0].label, "review");
    assert!(state.snapshot.as_ref().unwrap().tabs[0].custom_label);
    state.open_rename_tab_overlay();
    let Some(ClientShellOverlay::Rename(overlay)) = &state.overlay else {
        panic!("rename overlay");
    };
    assert!(
        matches!(&overlay.target, ClientRenameTarget::Tab { original_name, .. } if original_name == "review")
    );
}

#[test]
fn hrdr28_inactive_tabs_keep_only_their_own_agent_title() {
    let mut projected = snapshot();
    projected.tabs[0].label = "codex".into();
    let mut second = projected.tabs[0].clone();
    second.tab_id = "tab_2".into();
    second.number = 2;
    second.focused = false;
    projected.tabs.push(second);
    projected.agents = vec![
        titled_agent(&projected.tabs[0], "pane_1", Some("alpha")),
        titled_agent(&projected.tabs[1], "pane_2", Some("beta")),
    ];
    let mut state = state_with(projected);
    let row = tab_strip(&mut state, 120);
    assert!(row.contains("codex · alpha"), "{row}");
    assert!(row.contains("codex · beta"), "{row}");
    assert_eq!(state.hits.tabs.len(), 2);
    assert_eq!(state.hits.tabs[1].1, "tab_2");
}

#[test]
fn hrdr28_split_agents_require_an_explicit_focused_agent() {
    let mut projected = snapshot();
    projected.tabs[0].label = "agents".into();
    projected.agents = vec![
        titled_agent(&projected.tabs[0], "pane_1", Some("alpha")),
        titled_agent(&projected.tabs[0], "pane_2", Some("beta")),
    ];
    let mut state = state_with(projected.clone());
    let row = tab_strip(&mut state, 120);
    assert!(!row.contains("alpha") && !row.contains("beta"), "{row}");
    projected.agents[1].focused = true;
    state.set_snapshot(Box::new(projected.clone()));
    let row = tab_strip(&mut state, 120);
    assert!(
        row.contains("agents · beta") && !row.contains("alpha"),
        "{row}"
    );
    projected.agents[1].terminal_title_stripped = None;
    state.set_snapshot(Box::new(projected));
    let row = tab_strip(&mut state, 120);
    assert!(!row.contains("alpha") && !row.contains("beta"), "{row}");
}

#[test]
fn hrdr28_empty_duplicate_and_spinner_titles_do_not_add_noise() {
    for title in [None, Some(""), Some("  "), Some("codex")] {
        let mut projected = snapshot();
        projected.tabs[0].label = "codex".into();
        let mut agent = titled_agent(&projected.tabs[0], "pane_1", title);
        agent.terminal_title = Some("⠋ raw title".into());
        projected.agents = vec![agent];
        let mut state = state_with(projected);
        let row = tab_strip(&mut state, 80);
        assert!(
            !row.contains('·') && !row.contains("raw title"),
            "{title:?}: {row}"
        );
    }
}

#[test]
fn hrdr28_unicode_zoom_and_narrow_tabs_keep_valid_hit_targets() {
    let mut projected = snapshot();
    projected.tabs[0].label = "codex".into();
    projected.tabs[0].zoomed = true;
    projected.agents = vec![titled_agent(&projected.tabs[0], "pane_1", Some("修复🙂"))];
    let mut state = state_with(projected.clone());
    let row = tab_strip(&mut state, 120);
    assert!(row.contains("codex · 修复🙂 Z"), "{row}");
    projected.agents[0].terminal_title_stripped = Some("long title ".repeat(30));
    state.set_snapshot(Box::new(projected));
    for width in [25, 40, 80] {
        let frame = state.compose(width, 20).expect("narrow frame");
        assert_eq!(frame.width, width);
        assert!(state
            .hits
            .tabs
            .iter()
            .all(|(rect, _)| rect.right() <= width));
        if let Some((_, tab_id)) = state.hits.tabs.first() {
            assert_eq!(tab_id, "tab_1");
        }
        if width == 80 {
            assert!(!state.hits.tabs.is_empty());
        }
    }
}

#[test]
#[ignore = "manual fixed-geometry title rendering profile"]
fn hrdr28_render_scale_profile() {
    for count in [1, 15] {
        let mut projected = snapshot();
        projected.tabs.clear();
        projected.panes.clear();
        let template = snapshot().tabs.remove(0);
        let pane_template = snapshot().panes.remove(0);
        for index in 0..count {
            let mut tab = template.clone();
            tab.tab_id = format!("tab_{}", index + 1);
            tab.number = index + 1;
            tab.label = "codex".into();
            tab.focused = index == 0;
            let pane_id = format!("pane_{}", index + 1);
            let mut pane = pane_template.clone();
            pane.pane_id = pane_id.clone();
            pane.tab_id = tab.tab_id.clone();
            pane.focused = tab.focused;
            projected.panes.push(pane);
            projected
                .agents
                .push(titled_agent(&tab, &pane_id, Some("session")));
            projected.tabs.push(tab);
        }
        let mut state = state_with(projected);
        for _ in 0..30 {
            std::hint::black_box(state.compose(120, 24));
        }
        let started = std::time::Instant::now();
        for _ in 0..1000 {
            std::hint::black_box(state.compose(120, 24));
        }
        println!(
            "hrdr28 tabs={count} geometry=120x24 mean_us={:.2}",
            started.elapsed().as_secs_f64() * 1000.0
        );
        let replacement = (**state.snapshot.as_ref().unwrap()).clone();
        let started = std::time::Instant::now();
        for _ in 0..1000 {
            state.set_snapshot(Box::new(replacement.clone()));
        }
        println!(
            "hrdr28 snapshot_apply panes={count} mean_us={:.2}",
            started.elapsed().as_secs_f64() * 1000.0
        );
    }
}

#[test]
fn hrdr28_endpoint_local_tab_ids_do_not_mix_session_titles() {
    let mut local = snapshot();
    local.tabs[0].label = "codex".into();
    local.agents = vec![titled_agent(
        &local.tabs[0],
        "pane_1",
        Some("local session"),
    )];
    let mut state = state_with(local);
    let profile =
        crate::client::endpoint::SavedSshEndpoint::new("Remote", "dev@build.example", "agents")
            .expect("profile");
    let endpoint_id = crate::client::endpoint::ClientEndpointId::Ssh(profile.id.clone());
    state.set_endpoint_catalog(&[profile]);
    state.set_endpoint_status(
        &endpoint_id,
        crate::client::endpoint::ClientEndpointStatus::Online,
    );
    let mut remote = snapshot();
    remote.boot_id = "remote-boot".into();
    remote.tabs[0].label = "codex".into();
    remote.agents = vec![titled_agent(
        &remote.tabs[0],
        "pane_1",
        Some("remote session"),
    )];
    state.set_endpoint_snapshot(&endpoint_id, Box::new(remote));
    let row = tab_strip(&mut state, 120);
    assert!(row.contains("codex · local session"), "{row}");
    assert!(!row.contains("codex · remote session"), "{row}");
    assert!(state.activate_endpoint_projection(&endpoint_id));
    let mut remote_surface = surface();
    remote_surface.boot_id = "remote-boot".into();
    state.set_pane_surface(remote_surface);
    let row = tab_strip(&mut state, 120);
    assert!(row.contains("codex · remote session"), "{row}");
    assert!(!row.contains("codex · local session"), "{row}");
}

#[test]
fn hrdr28_title_growth_reveals_the_focused_tab_but_equal_width_keeps_manual_scroll() {
    let mut projected = snapshot();
    projected.tabs.clear();
    let template = snapshot().tabs.remove(0);
    for index in 1..=3 {
        let mut tab = template.clone();
        tab.tab_id = format!("tab_{index}");
        tab.number = index;
        tab.label = format!("t{index}");
        tab.focused = index == 3;
        projected
            .agents
            .push(titled_agent(&tab, &format!("pane_{index}"), Some("a")));
        projected.tabs.push(tab);
    }
    projected.focused_tab_id = Some("tab_3".into());
    projected.focused_pane_id = Some("pane_3".into());
    let mut state = state_with(projected.clone());
    state.compose(80, 20).unwrap();
    assert_eq!(state.tab_scroll, 0);
    assert!(state.hits.tabs.iter().any(|(_, id)| id == "tab_3"));
    projected.agents[0].terminal_title_stripped = Some("long session title ".repeat(8));
    state.set_snapshot(Box::new(projected.clone()));
    state.compose(80, 20).unwrap();
    assert!(
        state.hits.tabs.iter().any(|(_, id)| id == "tab_3"),
        "focused tab must remain visible"
    );
    state.tab_scroll = 0;
    state.reveal_focused_tab = false;
    projected.agents[0].terminal_title_stripped = Some("same session title ".repeat(8));
    state.set_snapshot(Box::new(projected));
    state.compose(80, 20).unwrap();
    assert_eq!(
        state.tab_scroll, 0,
        "equal-width titles must preserve manual scrolling"
    );
}
