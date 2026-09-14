//! `hrdr-1` wiring checks that need the composed frame or the full config path.

use super::*;

use super::super::sidebar_shape::SidebarShapeState;
use crate::config::SidebarCollapsedModeConfig;
use crate::input::{resolve_prefix_binding, KeybindAction, KeybindMatch, TerminalKey};

const EXPANDED: SidebarShapeState = SidebarShapeState {
    collapsed: false,
    mode_override: None,
    hide_restore: None,
};
const LOCKED_COMPACT: SidebarShapeState = SidebarShapeState {
    collapsed: true,
    mode_override: Some(SidebarCollapsedModeConfig::Compact),
    hide_restore: None,
};
const COLLAPSED_GLOBAL: SidebarShapeState = SidebarShapeState {
    collapsed: true,
    mode_override: None,
    hide_restore: None,
};

#[test]
fn sidebar_shape_keys_reach_clients_through_the_keybinding_profile() {
    for (user_config, key, action) in [
        ("", 'B', KeybindAction::ToggleSidebarHidden),
        (
            "[keys]\ntoggle_sidebar_hidden = \"prefix+shift+c\"\n",
            'C',
            KeybindAction::ToggleSidebarHidden,
        ),
        (
            "[keys]\ntoggle_sidebar_compact = \"prefix+shift+c\"\n",
            'C',
            KeybindAction::ToggleSidebarCompact,
        ),
    ] {
        let config: Config = toml::from_str(user_config).expect("user config");
        let profile = config
            .local_keybindings_profile_toml()
            .expect("keybinding profile");
        let published =
            crate::config::keybindings_from_profile_toml(&profile).expect("published keybinds");
        let shifted = TerminalKey::new(KeyCode::Char(key), KeyModifiers::SHIFT);
        assert!(
            matches!(
                resolve_prefix_binding(&published.keybinds, &shifted),
                Some(KeybindMatch::Action(resolved)) if resolved == action
            ),
            "{action:?} on shift+{key}: {profile}"
        );
    }
}

/// Fork servers publish `toggle_sidebar_compact` and `toggle_sidebar_hidden` in the keybinding
/// profile, and older or upstream clients must still accept a profile with keys they don't
/// know. This guards the shared parser's tolerance across upstream syncs.
#[test]
fn keybinding_profile_with_unknown_keys_still_parses() {
    let published = crate::config::keybindings_from_profile_toml(
        "[keys]\nprefix = \"ctrl+b\"\ntoggle_sidebar_future = \"prefix+y\"\n",
    )
    .expect("profile with an unknown key parses");
    let shifted = TerminalKey::new(KeyCode::Char('B'), KeyModifiers::SHIFT);
    assert!(matches!(
        resolve_prefix_binding(&published.keybinds, &shifted),
        Some(KeybindMatch::Action(KeybindAction::ToggleSidebarHidden))
    ));
}

fn click_sidebar_toggle(state: &mut ClientShellState) -> ClientShellInput {
    state.set_pane_surface(surface());
    state.compose(106, 30).expect("sidebar frame");
    let toggle = state.hits.sidebar_toggle;
    assert!(toggle.width > 0 && toggle.height > 0, "{toggle:?}");
    state.handle_raw_events(vec![RawInputEvent::Mouse(MouseEvent {
        kind: MouseEventKind::Down(MouseButton::Left),
        column: toggle.x,
        row: toggle.y,
        modifiers: KeyModifiers::empty(),
    })])
}

#[test]
fn sidebar_toggle_click_expands_a_locked_strip_under_global_hidden() {
    let mut config = Config::default();
    config.ui.sidebar_collapsed_mode = SidebarCollapsedModeConfig::Hidden;
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&config));
    state.set_snapshot(Box::new(snapshot()));
    state.record_binding(
        KeybindMatch::Action(KeybindAction::ToggleSidebarCompact),
        &mut ClientShellInput::default(),
    );
    assert_eq!(state.sidebar_shape(), LOCKED_COMPACT);

    let outcome = click_sidebar_toggle(&mut state);
    assert!(outcome.repaint && outcome.resize);
    assert_eq!(state.sidebar_shape(), EXPANDED);
    assert_eq!(state.layout(106, 30).sidebar.width, 26);

    // From expanded, the click collapses to the global mode (the Interaction design
    // table), which here is hidden: the lock was dropped by the expand.
    click_sidebar_toggle(&mut state);
    assert_eq!(state.sidebar_shape(), COLLAPSED_GLOBAL);
    assert_eq!(state.layout(106, 30).sidebar.width, 0);
}
