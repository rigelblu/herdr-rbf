//! hrdr-30.2: a tab showing one agent (an attach client) ignores outer focus for that agent's
//! notification. Each test runs the same inputs through an attach-mode shell and a full-view
//! shell, so the full-view half proves upstream's rules still hold there.
use super::*;
use crate::client::shell::state::ClientShellNotificationEffect as Effect;

fn shell(attached: bool) -> ClientShellState {
    let mut config = ClientShellConfig::from_config(&Config::default());
    if attached {
        config = config.with_attached_terminal();
    }
    config.toast_delivery = crate::config::ToastDelivery::Terminal;
    config.toast_delay_seconds = 0;
    ClientShellState::new(config)
}

fn agent_snapshot(revision: u64, status: AgentStatus, sequence: u64) -> Box<ClientShellSnapshot> {
    let mut projected = snapshot();
    projected.revision = revision;
    projected.agents.push(ClientShellAgent {
        pane_id: "pane_1".into(),
        workspace_id: "ws_1".into(),
        tab_id: "tab_1".into(),
        name: None,
        display_agent: Some("pi".into()),
        agent: Some("pi".into()),
        title: None,
        terminal_title: None,
        terminal_title_stripped: None,
        agent_status: status,
        state_change_seq: sequence,
        state_labels: Vec::new(),
        tokens: Vec::new(),
        focused: true,
    });
    Box::new(projected)
}

fn surface_at(revision: u64) -> PaneSurfaceFrame {
    let mut frame = surface();
    frame.projection_revision = revision;
    frame
}

fn event(kind: SemanticNotificationKind) -> SemanticNotification {
    SemanticNotification {
        kind,
        title: "pi finished".into(),
        body: Some("repro · 1 · 1".into()),
        sound: Some(match kind {
            SemanticNotificationKind::NeedsAttention => SemanticNotificationSound::Request,
            _ => SemanticNotificationSound::Done,
        }),
        agent: Some("pi".into()),
        workspace_id: Some("ws_1".into()),
        tab_id: Some("tab_1".into()),
        pane_id: Some("pane_1".into()),
        position: None,
    }
}

fn deliver(state: &mut ClientShellState, kind: SemanticNotificationKind) -> Vec<Effect> {
    let now = std::time::Instant::now();
    let (mut effects, _) = state.receive_notification(&ClientEndpointId::Local, event(kind), now);
    effects.extend(state.tick_notifications(now).0);
    effects
}

fn projected_status(state: &ClientShellState) -> AgentStatus {
    state.snapshot.as_ref().expect("snapshot").agents[0].agent_status
}

fn terminal_count(effects: &[Effect]) -> usize {
    effects
        .iter()
        .filter(|effect| matches!(effect, Effect::Terminal { .. }))
        .count()
}

fn sounds(effects: &[Effect], wanted: crate::sound::Sound) -> usize {
    effects
        .iter()
        .filter(|effect| matches!(effect, Effect::Sound { sound, .. } if *sound == wanted))
        .count()
}

fn sound_count(effects: &[Effect]) -> usize {
    sounds(effects, crate::sound::Sound::Done)
}

fn request_sound_count(effects: &[Effect]) -> usize {
    sounds(effects, crate::sound::Sound::Request)
}

fn focus_lost(state: &mut ClientShellState) {
    state.handle_raw_events(vec![RawInputEvent::OuterFocusLost]);
}

/// 5a: the surface is installed first, then the snapshot that turns the pane Done arrives
/// at the surface's own revision (the snapshot path, `cache_endpoint_snapshot_with_surface`).
fn surface_first(attached: bool, focus: Option<bool>) -> (AgentStatus, Vec<Effect>) {
    let mut state = shell(attached);
    state.outer_focused = focus;
    state.set_snapshot(agent_snapshot(1, AgentStatus::Working, 1));
    state.set_pane_surface(surface_at(1));
    state.set_snapshot(agent_snapshot(1, AgentStatus::Idle, 2));
    let effects = deliver(&mut state, SemanticNotificationKind::Finished);
    (projected_status(&state), effects)
}

/// 5b: the Done snapshot arrives first, then the surface is installed
/// (`install_pane_surface` -> `acknowledge_active_surface_agents`).
fn snapshot_first(attached: bool, focus: Option<bool>) -> (AgentStatus, Vec<Effect>) {
    let mut state = shell(attached);
    state.outer_focused = focus;
    state.set_snapshot(agent_snapshot(1, AgentStatus::Working, 1));
    state.set_snapshot(agent_snapshot(2, AgentStatus::Idle, 2));
    state.set_pane_surface(surface_at(2));
    let effects = deliver(&mut state, SemanticNotificationKind::Finished);
    (projected_status(&state), effects)
}

#[test]
fn attach_tab_prints_own_finished_when_surface_first_and_told_focused() {
    let (status, effects) = surface_first(true, Some(true));
    assert_eq!(
        status,
        AgentStatus::Done,
        "attach tab must not mark its own agent seen"
    );
    assert_eq!(
        terminal_count(&effects),
        1,
        "attach tab prints its own agent's finished"
    );

    let (status, effects) = surface_first(false, Some(true));
    assert_eq!(
        status,
        AgentStatus::Idle,
        "a full view marks the drawn agent seen"
    );
    assert_eq!(
        terminal_count(&effects),
        0,
        "a full view stays quiet for what it shows"
    );
}

#[test]
fn attach_tab_prints_own_finished_when_snapshot_first_and_told_focused() {
    let (status, effects) = snapshot_first(true, Some(true));
    assert_eq!(
        status,
        AgentStatus::Done,
        "attach tab must not mark its own agent seen"
    );
    assert_eq!(
        terminal_count(&effects),
        1,
        "attach tab prints its own agent's finished"
    );

    let (status, effects) = snapshot_first(false, Some(true));
    assert_eq!(
        status,
        AgentStatus::Idle,
        "a full view marks the drawn agent seen"
    );
    assert_eq!(
        terminal_count(&effects),
        0,
        "a full view stays quiet for what it shows"
    );
}

#[test]
fn attach_tab_prints_own_finished_when_focus_is_gained() {
    let run = |attached: bool| {
        let mut state = shell(attached);
        focus_lost(&mut state);
        state.set_snapshot(agent_snapshot(1, AgentStatus::Working, 1));
        state.set_pane_surface(surface_at(1));
        state.set_snapshot(agent_snapshot(1, AgentStatus::Idle, 2));
        assert_eq!(
            projected_status(&state),
            AgentStatus::Done,
            "set-up: an unfocused tab has not marked the pane seen"
        );
        state.handle_raw_events(vec![RawInputEvent::OuterFocusGained]);
        assert_eq!(state.outer_focused, Some(true), "set-up: focus was gained");
        let effects = deliver(&mut state, SemanticNotificationKind::Finished);
        (projected_status(&state), effects)
    };
    let (status, effects) = run(true);
    assert_eq!(
        status,
        AgentStatus::Done,
        "gaining focus must not mark an attach tab's agent seen"
    );
    assert_eq!(
        terminal_count(&effects),
        1,
        "attach tab prints its own agent's finished"
    );

    let (status, effects) = run(false);
    assert_eq!(
        status,
        AgentStatus::Idle,
        "a full view marks the drawn agent seen on focus gained"
    );
    assert_eq!(
        terminal_count(&effects),
        0,
        "a full view stays quiet for what it shows"
    );
}

#[test]
fn attach_tab_plays_its_agents_sound_whatever_the_focus() {
    let (_, effects) = snapshot_first(true, Some(true));
    assert_eq!(
        sound_count(&effects),
        1,
        "attach tab plays Done for its own agent"
    );
    let (_, effects) = snapshot_first(false, Some(true));
    assert_eq!(
        sound_count(&effects),
        0,
        "a full view stays silent for what it shows"
    );
}

#[test]
fn attach_tab_prints_own_finished_when_no_focus_report_has_arrived() {
    let (status, effects) = snapshot_first(true, None);
    assert_eq!(status, AgentStatus::Done);
    assert_eq!(terminal_count(&effects), 1);
    assert_eq!(sound_count(&effects), 1);
}

#[test]
fn unfocused_tabs_print_their_own_finished_in_both_modes() {
    for attached in [true, false] {
        let (status, effects) = snapshot_first(attached, Some(false));
        assert_eq!(status, AgentStatus::Done, "attached: {attached}");
        assert_eq!(terminal_count(&effects), 1, "attached: {attached}");
        assert_eq!(sound_count(&effects), 1, "attached: {attached}");
    }
}

#[test]
fn needs_attention_prints_in_an_attach_tab_but_a_focused_full_view_stays_quiet() {
    let run = |attached: bool, focus: Option<bool>| {
        let mut state = shell(attached);
        state.outer_focused = focus;
        state.set_snapshot(agent_snapshot(1, AgentStatus::Blocked, 1));
        state.set_pane_surface(surface_at(1));
        deliver(&mut state, SemanticNotificationKind::NeedsAttention)
    };
    assert_eq!(terminal_count(&run(true, Some(true))), 1);
    assert_eq!(terminal_count(&run(true, None)), 1);
    assert_eq!(terminal_count(&run(false, Some(true))), 0);
    assert_eq!(terminal_count(&run(false, Some(false))), 1);
    // The request sound is never suppressed by focus (only the Finished sound is): an attach tab
    // plays it at any report, and so does a focused full view, which stays quiet on screen.
    for (attached, focus) in [
        (true, Some(true)),
        (true, None),
        (false, Some(true)),
        (false, Some(false)),
    ] {
        let effects = run(attached, focus);
        assert_eq!(
            request_sound_count(&effects),
            1,
            "request sound, attached: {attached}, focus: {focus:?}"
        );
        assert_eq!(
            sound_count(&effects),
            0,
            "no done sound for a needs-attention"
        );
    }
}

#[test]
fn a_full_view_keeps_the_quiet_rule_for_a_current_finished() {
    // No surface is installed, so nothing marks the pane seen: the "finished" stays current and
    // only the quiet rule (upstream's, in `tick_notifications`) decides.
    let run = |focus: Option<bool>| {
        let mut state = shell(false);
        state.outer_focused = focus;
        state.set_snapshot(agent_snapshot(1, AgentStatus::Working, 1));
        state.set_snapshot(agent_snapshot(2, AgentStatus::Idle, 2));
        assert_eq!(
            projected_status(&state),
            AgentStatus::Done,
            "set-up: the finished is current"
        );
        deliver(&mut state, SemanticNotificationKind::Finished)
    };
    let focused = run(Some(true));
    assert_eq!(
        terminal_count(&focused),
        0,
        "focused full view prints nothing"
    );
    assert_eq!(sound_count(&focused), 0, "focused full view plays nothing");
    let unfocused = run(Some(false));
    assert_eq!(terminal_count(&unfocused), 1, "unfocused full view prints");
    assert_eq!(sound_count(&unfocused), 1, "unfocused full view plays");
}

/// A notification buffered during the attach is replayed before the tab's first projection.
/// That projection marks every agent's current state seen, so a "finished" for the tab's own
/// pane goes stale; a "needs attention" does not.
#[test]
fn a_finished_buffered_during_the_attach_goes_stale_but_needs_attention_survives() {
    use crate::protocol::endpoint::EndpointAgentCompletions;
    let run = |kind: SemanticNotificationKind, status: AgentStatus| {
        let mut state = shell(true);
        let now = std::time::Instant::now();
        // The replay: the buffered notification first, then the first projection (a new boot).
        let (mut effects, _) =
            state.receive_notification(&ClientEndpointId::Local, event(kind), now);
        state.set_endpoint_agent_completions(
            &ClientEndpointId::Local,
            1,
            EndpointAgentCompletions {
                boot_id: "boot-1".into(),
                revision: 1,
                completions: [("pane_1".to_string(), 5)].into_iter().collect(),
            },
        );
        state.set_endpoint_snapshot_for_generation(
            &ClientEndpointId::Local,
            1,
            agent_snapshot(1, status, 5),
        );
        effects.extend(
            state
                .tick_notifications(
                    now + super::super::notification_policy::COMPLETION_RECHECK_INTERVAL,
                )
                .0,
        );
        effects
    };
    assert_eq!(
        terminal_count(&run(SemanticNotificationKind::Finished, AgentStatus::Idle)),
        0,
        "the first projection marks the finished seen"
    );
    assert_eq!(
        terminal_count(&run(
            SemanticNotificationKind::NeedsAttention,
            AgentStatus::Blocked
        )),
        1,
        "a needs-attention survives the attach"
    );
}
