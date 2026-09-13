use super::*;

use crate::config::{SidebarCollapsedModeConfig, TabBarPositionConfig};
use crate::input::{resolve_prefix_binding, KeybindAction, KeybindMatch, TerminalKey};

fn press(state: &mut ClientShellState, action: KeybindAction) -> ClientShellInput {
    let mut outcome = ClientShellInput::default();
    state.record_binding(KeybindMatch::Action(action), &mut outcome);
    outcome
}

fn layout_at(
    config: &ClientShellConfig,
    cols: u16,
    tab_count: usize,
    tab_bar_hidden: bool,
) -> ClientShellLayout {
    config.layout(
        cols,
        40,
        false,
        tab_count,
        26,
        SidebarCollapsedModeConfig::Compact,
        tab_bar_hidden,
    )
}

fn preferences_path(name: &str) -> std::path::PathBuf {
    let path = std::env::temp_dir().join(format!(
        "herdr-tab-bar-hidden-{name}-{}.json",
        std::process::id()
    ));
    let _ = std::fs::remove_file(&path);
    path
}

fn state_with_preferences(path: &std::path::Path) -> ClientShellState {
    ClientShellState::new(
        ClientShellConfig::from_config(&Config::default())
            .with_preferences_path(path.to_path_buf()),
    )
}

fn resolves_to(keybinds: &crate::config::Keybinds, key: char, action: KeybindAction) -> bool {
    let key = TerminalKey::new(KeyCode::Char(key), KeyModifiers::NONE);
    matches!(
        resolve_prefix_binding(keybinds, &key),
        Some(KeybindMatch::Action(resolved)) if resolved == action
    )
}

fn user_keybinds(toml: &str) -> crate::config::Keybinds {
    toml::from_str::<Config>(toml)
        .expect("user config")
        .live_keybinds_with_diagnostics()
        .expect("user keybinds")
        .0
        .keybinds
}

#[test]
fn tab_bar_hidden_layout_gives_the_row_back() {
    let mut config = ClientShellConfig::from_config(&Config::default());

    let shown = layout_at(&config, 120, 2, false);
    assert_eq!(
        (
            shown.tab_bar.height,
            shown.pane_surface.y,
            shown.pane_surface.height
        ),
        (1, 1, 39)
    );
    let hidden = layout_at(&config, 120, 2, true);
    assert_eq!(
        (
            hidden.tab_bar.height,
            hidden.pane_surface.y,
            hidden.pane_surface.height
        ),
        (0, 0, 40)
    );

    config.tab_bar_position = TabBarPositionConfig::Bottom;
    let shown = layout_at(&config, 120, 2, false);
    assert_eq!(
        (
            shown.tab_bar.y,
            shown.tab_bar.height,
            shown.pane_surface.y,
            shown.pane_surface.height
        ),
        (39, 1, 0, 39)
    );
    let hidden = layout_at(&config, 120, 2, true);
    assert_eq!(
        (
            hidden.tab_bar.height,
            hidden.pane_surface.y,
            hidden.pane_surface.height
        ),
        (0, 0, 40)
    );

    config.tab_bar_position = TabBarPositionConfig::Top;
    config.hide_tab_bar_when_single_tab = true;
    assert_eq!(layout_at(&config, 120, 1, false).tab_bar.height, 0);
    assert_eq!(layout_at(&config, 120, 1, true).tab_bar.height, 0);
    assert_eq!(layout_at(&config, 120, 2, false).tab_bar.height, 1);
    assert_eq!(layout_at(&config, 120, 2, true).tab_bar.height, 0);

    let mobile = config.mobile_width_threshold;
    let (shown, hidden) = (
        layout_at(&config, mobile, 2, false),
        layout_at(&config, mobile, 2, true),
    );
    assert_eq!(shown.tab_bar, hidden.tab_bar);
    assert_eq!(shown.mobile_header, hidden.mobile_header);
    assert_eq!(shown.pane_surface, hidden.pane_surface);
}

#[test]
fn toggle_tab_bar_defaults_to_prefix_t() {
    let defaults = crate::config::Keybinds::default();
    assert!(resolves_to(&defaults, 't', KeybindAction::ToggleTabBar));

    let moved = user_keybinds("[keys]\ntoggle_tab_bar = \"prefix+y\"\n");
    assert!(resolves_to(&moved, 'y', KeybindAction::ToggleTabBar));
    assert!(!resolves_to(&moved, 't', KeybindAction::ToggleTabBar));

    let taken = user_keybinds("[keys]\nnew_tab = \"prefix+t\"\n");
    assert!(resolves_to(&taken, 't', KeybindAction::NewTab));
    assert!(taken.toggle_tab_bar.bindings.is_empty());

    let groups =
        crate::input::keybind_help_groups(&defaults, (KeyCode::Char('b'), KeyModifiers::CONTROL));
    let (_, panes) = groups
        .iter()
        .find(|(name, _)| *name == "panes")
        .expect("panes help group");
    let hidden_sidebar = panes
        .iter()
        .position(|(_, label)| label == "toggle hidden sidebar")
        .expect("hidden sidebar row");
    let (key, label) = &panes[hidden_sidebar + 1];
    assert_eq!(
        (key.as_str(), label.as_ref()),
        ("prefix+t", "toggle tab bar")
    );
}

#[test]
fn toggle_tab_bar_restores_the_row() {
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    assert_eq!(state.layout(120, 40).pane_surface.height, 39);

    let outcome = press(&mut state, KeybindAction::ToggleTabBar);
    assert!(outcome.resize && outcome.repaint);
    assert_eq!(state.layout(120, 40).pane_surface.height, 40);

    press(&mut state, KeybindAction::ToggleSidebarHidden);
    let layout = state.layout(120, 40);
    assert_eq!((layout.sidebar.width, layout.pane_surface.height), (0, 40));

    let outcome = press(&mut state, KeybindAction::ToggleTabBar);
    assert!(outcome.resize && outcome.repaint);
    assert_eq!(state.layout(120, 40).pane_surface.height, 39);

    let mut two_tabs = snapshot();
    two_tabs.tabs.push(ClientShellTab {
        tab_id: "tab_2".into(),
        workspace_id: "ws_1".into(),
        number: 2,
        label: "2".into(),
        custom_label: false,
        zoomed: false,
        focused: false,
        agent_status: AgentStatus::Idle,
    });
    let mut state = ClientShellState::new(ClientShellConfig::from_config(&Config::default()));
    state.set_snapshot(Box::new(two_tabs));

    press(&mut state, KeybindAction::ToggleTabBar);
    state.set_pane_surface(surface());
    state.compose(80, 20).expect("hidden tab bar frame");
    assert!(state.hits.tabs.is_empty());
    assert_eq!(state.hits.new_tab.width, 0);

    press(&mut state, KeybindAction::ToggleTabBar);
    state.set_pane_surface(surface());
    state.compose(80, 20).expect("shown tab bar frame");
    assert_eq!(state.hits.tabs.len(), 2);
}

#[test]
fn tab_bar_hidden_preferences_round_trip() {
    let path = preferences_path("round-trip");
    let mut state = state_with_preferences(&path);
    press(&mut state, KeybindAction::ToggleTabBar);
    let saved = std::fs::read_to_string(&path).expect("preferences written");
    assert!(saved.contains("\"tab_bar_hidden\": true"), "{saved}");

    let mut reloaded = state_with_preferences(&path);
    assert_eq!(reloaded.layout(120, 40).pane_surface.height, 40);
    assert_eq!(reloaded.config.initial_surface_size(120, 40).rows, 40);

    press(&mut reloaded, KeybindAction::ToggleTabBar);
    let saved = std::fs::read_to_string(&path).expect("preferences rewritten");
    assert!(!saved.contains("tab_bar_hidden"), "{saved}");

    for legacy in [
        r#"{"sidebar_collapsed":true}"#,
        r#"{"tab_bar_hidden":false}"#,
    ] {
        std::fs::write(&path, legacy).expect("legacy preferences");
        assert_eq!(
            state_with_preferences(&path)
                .layout(120, 40)
                .pane_surface
                .height,
            39,
            "{legacy}"
        );
    }
    std::fs::remove_file(path).expect("remove preferences");
}

#[test]
fn tab_bar_hidden_at_bottom_keeps_the_mode_bar_on_the_last_row() {
    let last_row = |tab_bar_hidden: bool, mode: ClientShellMode| {
        let mut config = ClientShellConfig::from_config(&Config::default());
        config.tab_bar_position = TabBarPositionConfig::Bottom;
        let mut state = ClientShellState::new(config);
        state.set_snapshot(Box::new(snapshot()));
        if tab_bar_hidden {
            press(&mut state, KeybindAction::ToggleTabBar);
        }
        state.mode = mode;
        state.set_pane_surface(surface());
        let frame = state.compose(80, 20).expect("bottom tab bar frame");
        frame_rows(&frame).pop().expect("last row")
    };

    let hidden_prefix = last_row(true, ClientShellMode::Prefix);
    assert_eq!(hidden_prefix, last_row(false, ClientShellMode::Prefix));
    assert_ne!(hidden_prefix, last_row(true, ClientShellMode::Terminal));
}

#[test]
fn toggle_tab_bar_in_mobile_layout_saves_and_applies_once_wide() {
    let path = preferences_path("mobile");
    let mut state = state_with_preferences(&path);
    let mobile = state.config.mobile_width_threshold;
    state.set_snapshot(Box::new(snapshot()));
    state.set_pane_surface(surface());
    let _ = state.compose(mobile, 20);
    let before = state.layout(mobile, 20);

    let outcome = press(&mut state, KeybindAction::ToggleTabBar);
    assert!(outcome.resize && outcome.repaint);
    assert!(state.tab_bar_hidden);
    assert_eq!(state.layout(mobile, 20).pane_surface, before.pane_surface);
    let saved = std::fs::read_to_string(&path).expect("preferences written");
    assert!(saved.contains("\"tab_bar_hidden\": true"), "{saved}");
    assert_eq!(state.layout(120, 40).pane_surface.height, 40);
    std::fs::remove_file(path).expect("remove preferences");
}

#[test]
fn toggle_tab_bar_reaches_clients_through_the_keybinding_profile() {
    for (user_config, key) in [("", 't'), ("[keys]\ntoggle_tab_bar = \"prefix+y\"\n", 'y')] {
        let config: Config = toml::from_str(user_config).expect("user config");
        let profile = config
            .local_keybindings_profile_toml()
            .expect("keybinding profile");
        let published =
            crate::config::keybindings_from_profile_toml(&profile).expect("published keybinds");
        assert!(
            resolves_to(&published.keybinds, key, KeybindAction::ToggleTabBar),
            "{profile}"
        );
    }
}

#[test]
fn toggle_tab_bar_keeps_other_saved_preferences() {
    let path = preferences_path("coexist");
    let mut state = state_with_preferences(&path);
    state.sidebar_width = 31;
    state.sidebar_width_manual = true;
    state.sidebar_collapsed = true;
    state.sidebar_collapsed_manual = true;
    state.collapsed_groups.insert("repo-one".into());
    state.persist_chrome_preferences(&mut ClientShellInput::default());
    let seeded = std::fs::read_to_string(&path).expect("seeded preferences");

    press(&mut state, KeybindAction::ToggleTabBar);
    let hidden = state_with_preferences(&path);
    assert!(hidden.tab_bar_hidden);
    assert_eq!((hidden.sidebar_width, hidden.sidebar_collapsed), (31, true));
    assert!(hidden.collapsed_groups.contains("repo-one"));

    press(&mut state, KeybindAction::ToggleTabBar);
    let shown = std::fs::read_to_string(&path).expect("preferences after showing");
    assert_eq!(shown, seeded);
    std::fs::remove_file(path).expect("remove preferences");
}
