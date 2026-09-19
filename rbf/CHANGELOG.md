---
title: herdr-rbf RBF Changelog
---

Flavour releases use the version in `rbf/RBF_VERSION`; upstream's release history stays in the root `CHANGELOG.md`.

# 🔵⋯ [Unreleased]

---

# 🔵⋯ v0.7.0 (2026-09-19)
## 🟠⋯ 🚨 Breaking Changes for End Users
- 2026-09-19 - refactor (user need) | `herdr-agent install` is now `herdr-agent cmux-restart`, and it only adds cmux's restart entries; `rbf/scripts/install-rbf.sh` installs the command itself (#hrdr-9)

## 🟠⋯ Added for End Users
- 2026-09-19 - feat (user need) | herdr-agent now lives in the fork (`rbf/src/herdr-agent`) and installs with it into `~/.local`: type `claude`, `codex`, `pi` or `agy` in a cmux tab and the agent runs in this checkout's herdr session, so closing the tab or restarting cmux doesn't stop it (#hrdr-9)
- 2026-09-19 - feat (user need) | `rbf/scripts/install-rbf.sh --herdr-agent` installs herdr-agent alone, with no build and no session handoff. Each copy is checked before it goes live, and `--herdr-agent --rollback` puts the previous one back without touching `herdr` or any session (#hrdr-9)

## 🟠⋯ Added for Technical Users
- 2026-09-19 - feat (technical) | exit code `3` now also means herdr-agent's part didn't finish after `herdr` installed: herdr-agent itself, cmux's restart entries, or keeping its rollback target. `--herdr-agent` needs `python3`, as the plain install already did (#hrdr-9)

## 🟠⋯ Fixed for Builders
- 2026-09-19 - fix (technical) | the install test harness no longer names a home folder or drive: it takes its scratch root from `$EXTERNAL_DRIVE` (override with `RBF_TEST_ROOT`) (#hrdr-9)

---

# 🔵⋯ v0.6.0 (2026-09-18)
## 🟠⋯ Added for End Users
- 2026-09-17 - feat (user need) | copy Codex replies without display-only wrap breaks or reply gutters while preserving Codex's real line breaks, with an explicit copied-as-shown fallback whenever the saved reply cannot prove the reconstruction
- 2026-09-18 - feat (user need) | the copy toast now says what happened: `copied · rejoined N wrapped lines` when herdr changed the text, `copied as shown · agent text unavailable` when it wanted Codex's text and couldn't get it — no hook, no session id, an unreadable session file, a spent budget, or rows matching two saved replies differently — and `copied to clipboard` otherwise, including every drag over command output, a diff or a tool row in a Codex pane

## 🟠⋯ Added for Technical Users
- 2026-09-18 - feat (technical) | `join_agent_wraps` under `[ui.copy]` turns the joining off (default `true`); the server reads it on `herdr server reload-config`. The join runs server-side, so the machine hosting the pane is the one to configure
- 2026-09-18 - feat (technical) | new advertised method `pane.selection.read_joined`, alongside the unchanged `pane.selection.read`. A client that meets a server without it copies exactly as before

---

# 🔵⋯ v0.5.0 (2026-09-17)
## 🟠⋯ Added for End Users
- 2026-09-17 - feat (user need) | a cmux tab showing an agent through `herdr terminal attach` now shows the agent's own title, status symbol included, and follows its renames, so you can find an agent by its tab name

## 🟠⋯ Added for Technical Users
- 2026-09-17 - feat (technical) | `herdr terminal attach` writes its pane's title to the terminal it runs in and keeps it current; a pane with no title sends nothing. `ui.window_title = ""` turns this off too, along with herdr's own window titles

## 🟠⋯ Fixed for End Users
- 2026-09-17 - fix (user need) | `herdr pane list` no longer loses pane titles after an install, so the `herdr-agent` picker keeps its names and a tab that attaches again is named at once

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
