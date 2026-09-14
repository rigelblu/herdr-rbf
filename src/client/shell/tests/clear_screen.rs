//! herdr-rbf `hrdr-4`: ⌘K (`keys.clear_screen`) on the client.

use super::*;

use crate::input::{resolve_direct_binding, KeybindAction, KeybindMatch, TerminalKey};

fn super_key(key: char) -> TerminalKey {
    TerminalKey::new(KeyCode::Char(key), KeyModifiers::SUPER)
}

fn direct_action(keybinds: &crate::config::Keybinds, key: &TerminalKey) -> Option<KeybindAction> {
    match resolve_direct_binding(keybinds, key) {
        Some(KeybindMatch::Action(action)) => Some(action),
        _ => None,
    }
}

fn user_keybinds(toml: &str) -> crate::config::Keybinds {
    toml::from_str::<Config>(toml)
        .expect("user config")
        .live_keybinds_with_diagnostics()
        .expect("user keybinds")
        .0
        .keybinds
}

fn press_clear_screen(state: &mut ClientShellState) -> ClientShellInput {
    let mut outcome = ClientShellInput::default();
    state.record_binding(
        KeybindMatch::Action(KeybindAction::ClearScreen),
        &mut outcome,
    );
    outcome
}

fn state_with_focused_pane() -> ClientShellState {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    state
}

#[test]
fn clear_screen_defaults_to_cmd_k_and_rebinds() {
    let defaults = crate::config::Keybinds::default();
    assert_eq!(
        direct_action(&defaults, &super_key('k')),
        Some(KeybindAction::ClearScreen)
    );

    let moved = user_keybinds("[keys]\nclear_screen = \"cmd+j\"\n");
    assert_eq!(
        direct_action(&moved, &super_key('j')),
        Some(KeybindAction::ClearScreen)
    );
    assert_eq!(direct_action(&moved, &super_key('k')), None);

    let unset = user_keybinds("[keys]\nclear_screen = \"\"\n");
    assert_eq!(direct_action(&unset, &super_key('k')), None);

    let taken = user_keybinds("[keys]\nnew_tab = \"cmd+k\"\n");
    assert_eq!(
        direct_action(&taken, &super_key('k')),
        Some(KeybindAction::NewTab)
    );
    assert!(taken.clear_screen.bindings.is_empty());

    let groups =
        crate::input::keybind_help_groups(&defaults, (KeyCode::Char('b'), KeyModifiers::CONTROL));
    let (_, panes) = groups
        .iter()
        .find(|(name, _)| *name == "panes")
        .expect("panes help group");
    let edit_scrollback = panes
        .iter()
        .position(|(_, label)| label == "edit scrollback")
        .expect("edit scrollback row");
    let (key, label) = &panes[edit_scrollback + 1];
    assert!(key == "cmd+k" || key == "super+k", "{key}");
    assert_eq!(label.as_ref(), "clear screen");
}

#[test]
fn clear_screen_reaches_clients_through_the_keybinding_profile() {
    for (user_config, key) in [("", 'k'), ("[keys]\nclear_screen = \"cmd+j\"\n", 'j')] {
        let config: Config = toml::from_str(user_config).expect("user config");
        let profile = config
            .local_keybindings_profile_toml()
            .expect("keybinding profile");
        let published =
            crate::config::keybindings_from_profile_toml(&profile).expect("published keybinds");
        assert_eq!(
            direct_action(&published.keybinds, &super_key(key)),
            Some(KeybindAction::ClearScreen),
            "{profile}"
        );
    }
}

#[test]
fn clear_screen_targets_the_focused_pane() {
    let mut state = state_with_focused_pane();

    let input = press_clear_screen(&mut state);

    assert!(input.requests.is_empty());
    assert!(matches!(
        &input.actions[..],
        [ClientShellAction::Endpoint { request, .. }]
            if matches!(
                &request.method,
                crate::api::schema::Method::PaneClearScreen(target)
                    if target.pane_id == "pane_1"
            )
    ));
}

#[test]
fn clear_screen_on_a_server_without_the_method_shows_a_notice() {
    let mut state = state_with_focused_pane();
    state.set_endpoint_methods(Some(vec!["pane.focus".into()]));

    let input = press_clear_screen(&mut state);

    assert!(input.actions.is_empty());
    let notice = state
        .visible_endpoint_notice
        .as_ref()
        .expect("unsupported action notice");
    assert_eq!(notice.key.kind, ClientEndpointNoticeKind::Unsupported);
    assert_eq!(notice.key.code, "pane.clear_screen");
    assert!(state.endpoint_error.is_none());
}
