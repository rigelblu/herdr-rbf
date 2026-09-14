---
title: herdr-rbf RBF Changelog
---

Flavour releases use the version in `rbf/RBF_VERSION`; upstream's release history stays in the root `CHANGELOG.md`.

# 🔵⋯ [Unreleased]
(empty)

---

# 🔵⋯ v0.4.0 (2026-09-14)
## 🟠⋯ Added for End Users
- 2026-09-14 - feat (user need) | `rbf/scripts/install-rbf.sh` builds the checked-out fork and installs it as your daily `herdr`, handing every running session to the new build without stopping its panes. `--dry-run` previews and `--rollback` undoes

## 🟠⋯ Added for Technical Users
- 2026-09-14 - feat (technical) | fork builds refuse `herdr update`, and the update notice and `herdr channel set` name the install script. Breaking: `herdr update` no longer works on fork builds, and open windows close during an install (reattach with `herdr session attach <name>`)

## 🟠⋯ Fixed for End Users
- 2026-09-14 - fix (user need) | one unrecognized value in your saved sidebar preferences no longer resets all of them; only that value falls back to its default

---

# 🔵⋯ v0.3.0 (2026-09-14)
## 🟠⋯ Added for End Users
- 2026-09-14 - feat (user need) | ⌘K clears the focused pane's screen and scrollback, the same as in cmux. Full-screen programs like vim only get a redraw

## 🟠⋯ Added for Technical Users
- 2026-09-14 - feat (technical) | new `keys.clear_screen` (default `cmd+k`) and socket method `pane.clear_screen`

---

# 🔵⋯ v0.2.0 (2026-09-13)
## 🟠⋯ Added for End Users
- 2026-09-13 - feat (user need) | hide the tab bar with `prefix+t` and give its row to your panes, and bring it back by pressing it again

## 🟠⋯ Added for Technical Users
- 2026-09-13 - feat (technical) | rebind the tab bar key with `keys.toggle_tab_bar`; a hidden tab bar stays hidden across relaunch and wins over `ui.hide_tab_bar_when_single_tab`

---

# 🔵⋯ v0.1.0 (2026-09-13)
## 🟠⋯ Added for End Users
- 2026-09-13 - feat (user need) | hide the sidebar with `prefix+shift+b`, and get back the shape you had by pressing it again

## 🟠⋯ Added for Technical Users
- 2026-09-13 - feat (technical) | bind `keys.toggle_sidebar_compact` to switch straight to the compact strip, and rebind hide with `keys.toggle_sidebar_hidden`
