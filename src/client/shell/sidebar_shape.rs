//! Sidebar shape transitions: expanded, compact strip, or hidden.
//!
//! Hidden stays a collapsed mode. The shape is `sidebar_collapsed` plus a per-session
//! override of `ui.sidebar_collapsed_mode` and the shape a hide returns to. Every
//! transition lives in [`next`] so the key actions and the sidebar toggle click share
//! one set of rules.

use serde::{Deserialize, Serialize};

use super::{ClientShellState, SidebarCollapsedModeConfig};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "lowercase")]
pub(super) enum SidebarHideRestore {
    Expanded,
    Compact,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum SidebarShapeToggle {
    /// `toggle_sidebar` and the sidebar toggle click.
    Collapsed,
    Compact,
    Hidden,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) struct SidebarShapeState {
    pub(super) collapsed: bool,
    /// `None` follows the global `ui.sidebar_collapsed_mode`.
    pub(super) mode_override: Option<SidebarCollapsedModeConfig>,
    pub(super) hide_restore: Option<SidebarHideRestore>,
}

impl SidebarShapeState {
    const EXPANDED: Self = Self {
        collapsed: false,
        mode_override: None,
        hide_restore: None,
    };
    const COMPACT: Self = Self {
        collapsed: true,
        mode_override: Some(SidebarCollapsedModeConfig::Compact),
        hide_restore: None,
    };

    pub(super) fn from_preferences(
        preferences: &super::preferences::ClientChromePreferences,
        start_collapsed: bool,
    ) -> Self {
        // The mode and restore shape are only meaningful beside a saved manual
        // `sidebar_collapsed`; they are written under the same gate.
        let saved = preferences.sidebar_collapsed;
        Self {
            collapsed: saved.unwrap_or(start_collapsed),
            mode_override: saved.and(preferences.sidebar_collapsed_mode),
            hide_restore: saved.and(preferences.sidebar_hide_restore),
        }
        .normalized()
    }

    pub(super) fn effective_mode(
        self,
        global_mode: SidebarCollapsedModeConfig,
    ) -> SidebarCollapsedModeConfig {
        self.mode_override.unwrap_or(global_mode)
    }

    /// Drops combinations that can't come from [`next`], such as a restore shape saved
    /// while expanded, so a hand-edited or stale preferences file loads as the safe reading.
    pub(super) fn normalized(self) -> Self {
        if !self.collapsed {
            return Self::EXPANDED;
        }
        Self {
            hide_restore: self
                .hide_restore
                .filter(|_| self.mode_override == Some(SidebarCollapsedModeConfig::Hidden)),
            ..self
        }
    }
}

pub(super) fn next(
    state: SidebarShapeState,
    action: SidebarShapeToggle,
    global_mode: SidebarCollapsedModeConfig,
) -> SidebarShapeState {
    let effective = state.collapsed.then(|| state.effective_mode(global_mode));
    match action {
        SidebarShapeToggle::Collapsed => SidebarShapeState {
            collapsed: !state.collapsed,
            ..SidebarShapeState::EXPANDED
        },
        SidebarShapeToggle::Compact => match effective {
            Some(SidebarCollapsedModeConfig::Compact) => SidebarShapeState::EXPANDED,
            _ => SidebarShapeState::COMPACT,
        },
        SidebarShapeToggle::Hidden => match effective {
            Some(SidebarCollapsedModeConfig::Hidden) => match state.hide_restore {
                Some(SidebarHideRestore::Compact) => SidebarShapeState::COMPACT,
                Some(SidebarHideRestore::Expanded) | None => SidebarShapeState::EXPANDED,
            },
            previous => SidebarShapeState {
                collapsed: true,
                mode_override: Some(SidebarCollapsedModeConfig::Hidden),
                hide_restore: Some(match previous {
                    Some(_) => SidebarHideRestore::Compact,
                    None => SidebarHideRestore::Expanded,
                }),
            },
        },
    }
}

impl ClientShellState {
    pub(super) fn sidebar_shape(&self) -> SidebarShapeState {
        SidebarShapeState {
            collapsed: self.sidebar_collapsed,
            mode_override: self.sidebar_collapsed_mode_override,
            hide_restore: self.sidebar_hide_restore,
        }
    }

    pub(super) fn effective_sidebar_collapsed_mode(&self) -> SidebarCollapsedModeConfig {
        self.sidebar_shape()
            .effective_mode(self.config.sidebar_collapsed_mode)
    }

    /// Applies one transition and marks the shape as a manual choice. Callers own the
    /// repaint, resize, and persistence side effects.
    pub(super) fn apply_sidebar_shape_action(&mut self, action: SidebarShapeToggle) {
        let shape = next(
            self.sidebar_shape(),
            action,
            self.config.sidebar_collapsed_mode,
        );
        self.sidebar_collapsed = shape.collapsed;
        self.sidebar_collapsed_mode_override = shape.mode_override;
        self.sidebar_hide_restore = shape.hide_restore;
        self.sidebar_collapsed_manual = true;
    }
}

#[cfg(test)]
mod tests {
    use super::SidebarCollapsedModeConfig::{Compact, Hidden};
    use super::SidebarShapeToggle as Toggle;
    use super::*;

    const fn shape(
        collapsed: bool,
        mode_override: Option<SidebarCollapsedModeConfig>,
        hide_restore: Option<SidebarHideRestore>,
    ) -> SidebarShapeState {
        SidebarShapeState {
            collapsed,
            mode_override,
            hide_restore,
        }
    }

    const EXPANDED: SidebarShapeState = SidebarShapeState::EXPANDED;
    const LOCKED_COMPACT: SidebarShapeState = SidebarShapeState::COMPACT;
    /// Collapsed and following the global mode, as `toggle_sidebar` leaves it.
    const COLLAPSED_GLOBAL: SidebarShapeState = shape(true, None, None);
    const HIDDEN_FROM_EXPANDED: SidebarShapeState =
        shape(true, Some(Hidden), Some(SidebarHideRestore::Expanded));
    const HIDDEN_FROM_COMPACT: SidebarShapeState =
        shape(true, Some(Hidden), Some(SidebarHideRestore::Compact));

    #[test]
    fn sidebar_shape_transition_table() {
        // (global mode, start shape, action, expected full written state).
        // Start shapes are how each shape is reached under that global mode:
        // compact is `COLLAPSED_GLOBAL` under Compact and the locked strip under Hidden;
        // hidden is `COLLAPSED_GLOBAL` under Hidden and a hide from compact under Compact.
        let cases = [
            // global mode: compact
            (Compact, EXPANDED, Toggle::Compact, LOCKED_COMPACT),
            (Compact, COLLAPSED_GLOBAL, Toggle::Compact, EXPANDED),
            (
                Compact,
                HIDDEN_FROM_COMPACT,
                Toggle::Compact,
                LOCKED_COMPACT,
            ),
            (Compact, EXPANDED, Toggle::Hidden, HIDDEN_FROM_EXPANDED),
            (
                Compact,
                COLLAPSED_GLOBAL,
                Toggle::Hidden,
                HIDDEN_FROM_COMPACT,
            ),
            (Compact, HIDDEN_FROM_COMPACT, Toggle::Hidden, LOCKED_COMPACT),
            (Compact, EXPANDED, Toggle::Collapsed, COLLAPSED_GLOBAL),
            (Compact, COLLAPSED_GLOBAL, Toggle::Collapsed, EXPANDED),
            (Compact, HIDDEN_FROM_COMPACT, Toggle::Collapsed, EXPANDED),
            // global mode: hidden
            (Hidden, EXPANDED, Toggle::Compact, LOCKED_COMPACT),
            (Hidden, LOCKED_COMPACT, Toggle::Compact, EXPANDED),
            (Hidden, COLLAPSED_GLOBAL, Toggle::Compact, LOCKED_COMPACT),
            (Hidden, EXPANDED, Toggle::Hidden, HIDDEN_FROM_EXPANDED),
            (Hidden, LOCKED_COMPACT, Toggle::Hidden, HIDDEN_FROM_COMPACT),
            (Hidden, COLLAPSED_GLOBAL, Toggle::Hidden, EXPANDED),
            (Hidden, EXPANDED, Toggle::Collapsed, COLLAPSED_GLOBAL),
            (Hidden, LOCKED_COMPACT, Toggle::Collapsed, EXPANDED),
            (Hidden, COLLAPSED_GLOBAL, Toggle::Collapsed, EXPANDED),
        ];
        for (global, start, action, expected) in cases {
            assert_eq!(
                next(start, action, global),
                expected,
                "{action:?} from {start:?} under global {global:?}"
            );
        }
    }

    #[test]
    fn sidebar_shape_transition_alternate_start_states() {
        // Shapes reached a second way: the locked strip under global Compact, and a
        // hide from expanded. Both must behave like the table's start states.
        for global in [Compact, Hidden] {
            assert_eq!(next(LOCKED_COMPACT, Toggle::Compact, global), EXPANDED);
            assert_eq!(
                next(LOCKED_COMPACT, Toggle::Hidden, global),
                HIDDEN_FROM_COMPACT
            );
            assert_eq!(next(LOCKED_COMPACT, Toggle::Collapsed, global), EXPANDED);
            assert_eq!(
                next(HIDDEN_FROM_EXPANDED, Toggle::Compact, global),
                LOCKED_COMPACT
            );
            assert_eq!(
                next(HIDDEN_FROM_EXPANDED, Toggle::Collapsed, global),
                EXPANDED
            );
        }
    }

    #[test]
    fn sidebar_shape_transition_hide_restores_expanded() {
        for global in [Compact, Hidden] {
            let hidden = next(EXPANDED, Toggle::Hidden, global);
            assert_eq!(hidden.effective_mode(global), Hidden);
            assert_eq!(next(hidden, Toggle::Hidden, global), EXPANDED);
        }
    }

    #[test]
    fn sidebar_shape_transition_hide_then_toggle_forgets_restore() {
        let hidden = next(COLLAPSED_GLOBAL, Toggle::Hidden, Compact);
        let expanded = next(hidden, Toggle::Collapsed, Compact);
        assert_eq!(expanded, EXPANDED);
        assert_eq!(
            next(expanded, Toggle::Hidden, Compact),
            HIDDEN_FROM_EXPANDED
        );
    }

    #[test]
    fn sidebar_shape_transition_survives_global_mode_change() {
        let hidden = next(COLLAPSED_GLOBAL, Toggle::Hidden, Compact);
        let restored = next(hidden, Toggle::Hidden, Hidden);
        assert_eq!(restored, LOCKED_COMPACT);
        assert_eq!(restored.effective_mode(Hidden), Compact);
    }

    fn press(state: &mut ClientShellState, action: crate::input::KeybindAction) {
        state.record_binding(
            crate::input::KeybindMatch::Action(action),
            &mut super::super::ClientShellInput::default(),
        );
    }

    fn sidebar_width(state: &ClientShellState) -> u16 {
        state.layout(120, 40).sidebar.width
    }

    fn preferences_path(name: &str) -> std::path::PathBuf {
        let path = std::env::temp_dir().join(format!(
            "herdr-sidebar-shape-{name}-{}.json",
            std::process::id()
        ));
        let _ = std::fs::remove_file(&path);
        path
    }

    fn state_with_preferences(path: &std::path::Path) -> ClientShellState {
        ClientShellState::new(
            super::super::ClientShellConfig::from_config(&crate::config::Config::default())
                .with_preferences_path(path.to_path_buf()),
        )
    }

    #[test]
    fn toggle_sidebar_hidden_defaults_to_prefix_shift_b() {
        use crossterm::event::{KeyCode, KeyModifiers};

        use crate::input::{resolve_prefix_binding, KeybindAction, KeybindMatch, TerminalKey};

        let shift_b = TerminalKey::new(KeyCode::Char('B'), KeyModifiers::SHIFT);
        let keybinds = crate::config::Keybinds::default();
        assert!(matches!(
            resolve_prefix_binding(&keybinds, &shift_b),
            Some(KeybindMatch::Action(KeybindAction::ToggleSidebarHidden))
        ));
        let config = crate::config::Config::default()
            .live_keybinds_with_diagnostics()
            .expect("default keybinds");
        assert!(config.0.keybinds.toggle_sidebar_compact.bindings.is_empty());

        let moved: crate::config::Config =
            toml::from_str("[keys]\ntoggle_sidebar_hidden = \"prefix+shift+c\"\n")
                .expect("user config");
        let moved = moved
            .live_keybinds_with_diagnostics()
            .expect("user keybinds")
            .0
            .keybinds;
        let shift_c = TerminalKey::new(KeyCode::Char('C'), KeyModifiers::SHIFT);
        assert!(matches!(
            resolve_prefix_binding(&moved, &shift_c),
            Some(KeybindMatch::Action(KeybindAction::ToggleSidebarHidden))
        ));
        assert!(!matches!(
            resolve_prefix_binding(&moved, &shift_b),
            Some(KeybindMatch::Action(KeybindAction::ToggleSidebarHidden))
        ));
    }

    #[test]
    fn sidebar_hide_restores_previous_shape() {
        use crate::input::KeybindAction::{ToggleSidebar, ToggleSidebarHidden};

        let mut state = ClientShellState::new(super::super::ClientShellConfig::from_config(
            &crate::config::Config::default(),
        ));
        assert_eq!(sidebar_width(&state), 26);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 0);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 26);

        press(&mut state, ToggleSidebar);
        assert_eq!(sidebar_width(&state), 4);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 0);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 4);

        press(&mut state, ToggleSidebarHidden);
        press(&mut state, ToggleSidebar);
        assert_eq!(sidebar_width(&state), 26);
    }

    #[test]
    fn sidebar_shape_preferences_round_trip_hidden_and_restore() {
        use crate::input::KeybindAction::{ToggleSidebar, ToggleSidebarHidden};

        let path = preferences_path("round-trip");
        let mut state = state_with_preferences(&path);
        press(&mut state, ToggleSidebar);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 0);

        let mut reloaded = state_with_preferences(&path);
        assert_eq!(sidebar_width(&reloaded), 0);
        let initial = reloaded.config.initial_surface_size(120, 40);
        assert_eq!(initial.cols, 120);
        press(&mut reloaded, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&reloaded), 4);
        std::fs::remove_file(path).expect("remove preferences");
    }

    #[test]
    fn sidebar_shape_preferences_load_legacy_and_inconsistent_files() {
        let path = preferences_path("legacy");
        std::fs::write(&path, r#"{"sidebar_collapsed":true}"#).expect("legacy preferences");
        assert_eq!(sidebar_width(&state_with_preferences(&path)), 4);

        std::fs::write(
            &path,
            r#"{"sidebar_collapsed":false,"sidebar_collapsed_mode":"hidden","sidebar_hide_restore":"compact"}"#,
        )
        .expect("inconsistent preferences");
        let state = state_with_preferences(&path);
        assert_eq!(sidebar_width(&state), 26);
        assert_eq!(state.sidebar_hide_restore, None);
        assert_eq!(state.sidebar_collapsed_mode_override, None);

        std::fs::write(&path, r#"{"sidebar_collapsed_mode":"hidden"}"#)
            .expect("override without a manual collapse");
        let state = state_with_preferences(&path);
        assert!(!state.sidebar_collapsed_manual);
        assert_eq!(state.sidebar_collapsed_mode_override, None);
        std::fs::remove_file(path).expect("remove preferences");
    }

    #[test]
    fn sidebar_compact_key_reaches_the_strip_under_global_hidden() {
        use crate::input::KeybindAction::ToggleSidebarCompact;

        let mut config = crate::config::Config::default();
        config.ui.sidebar_collapsed_mode = Hidden;
        let mut state =
            ClientShellState::new(super::super::ClientShellConfig::from_config(&config));
        press(&mut state, ToggleSidebarCompact);
        assert_eq!(sidebar_width(&state), 4);
        press(&mut state, ToggleSidebarCompact);
        assert_eq!(sidebar_width(&state), 26);
    }

    #[test]
    fn sidebar_shape_follows_live_global_mode_unless_locked() {
        use crate::input::KeybindAction::{ToggleSidebar, ToggleSidebarCompact};

        let mut hidden_config = crate::config::Config::default();
        hidden_config.ui.sidebar_collapsed_mode = Hidden;

        let mut following = ClientShellState::new(super::super::ClientShellConfig::from_config(
            &crate::config::Config::default(),
        ));
        press(&mut following, ToggleSidebar);
        assert_eq!(sidebar_width(&following), 4);
        following.config.apply_live_config(&hidden_config, &[], &[]);
        assert_eq!(sidebar_width(&following), 0);

        let mut locked = ClientShellState::new(super::super::ClientShellConfig::from_config(
            &crate::config::Config::default(),
        ));
        press(&mut locked, ToggleSidebarCompact);
        locked.config.apply_live_config(&hidden_config, &[], &[]);
        assert_eq!(sidebar_width(&locked), 4);
    }

    #[test]
    fn sidebar_hide_in_mobile_layout_applies_once_wide() {
        use crate::input::KeybindAction::ToggleSidebarHidden;

        let mut state = ClientShellState::new(super::super::ClientShellConfig::from_config(
            &crate::config::Config::default(),
        ));
        let mobile_cols = state.config.mobile_width_threshold;
        assert_eq!(state.layout(mobile_cols, 40).sidebar.width, 0);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(state.sidebar_shape(), HIDDEN_FROM_EXPANDED);
        assert_eq!(sidebar_width(&state), 0);
        press(&mut state, ToggleSidebarHidden);
        assert_eq!(sidebar_width(&state), 26);
    }

    #[test]
    fn profile_ignores_unknown_keys() {
        assert!(crate::config::keybindings_from_profile_toml(
            "[keys]\nprefix = \"ctrl+b\"\ntoggle_sidebar_future = \"prefix+y\"\n"
        )
        .is_ok());
    }

    #[test]
    fn sidebar_shape_normalizes_inconsistent_saved_state() {
        assert_eq!(
            shape(false, Some(Hidden), Some(SidebarHideRestore::Compact)).normalized(),
            EXPANDED
        );
        assert_eq!(
            shape(true, Some(Compact), Some(SidebarHideRestore::Compact)).normalized(),
            LOCKED_COMPACT
        );
        assert_eq!(HIDDEN_FROM_COMPACT.normalized(), HIDDEN_FROM_COMPACT);
    }
}
