---
title: herdr-rbf RBF
---

This directory holds this flavour's docs, scripts, and version metadata. The upstream project's own README stays at the repo root.

# 🔵⋯ Use
<who this is for, and what you're not taking on — issues, contributions, support>

# 🔵⋯ Context
<what this is a flavour of, why it exists, where the idea started>

# 🔵⋯ Features
## 🟠⋯ Separate keys for a compact sidebar and a hidden sidebar
- `prefix+shift+b` hides the sidebar completely. Press it again and you get back the shape you had, compact strip or full sidebar
- `keys.toggle_sidebar_compact` switches straight to the 4-column status strip, even when `ui.sidebar_collapsed_mode = "hidden"`. It's unset by default — add it under `[keys]` in `~/.config/herdr/config.toml`, e.g. `toggle_sidebar_compact = "prefix+shift+c"`
- Rebind the hide key with `keys.toggle_sidebar_hidden`
- `prefix+b` works as it always has
- The shape and what hide returns to survive a relaunch or reattach
- A hidden sidebar has no click target, so the key is the only way back. `prefix+?` lists both keys under `toggle sidebar`

## 🟠⋯ Hide the tab bar
- `prefix+t` hides the tab bar and gives its row to your panes. Press it again to bring it back
- Hidden stays hidden at any tab count, even where `ui.hide_tab_bar_when_single_tab` would show it, with the tab bar at the top or the bottom
- It stays hidden across a relaunch or reattach
- Hide the sidebar too (`prefix+shift+b`) and your pane fills the whole terminal
- `prefix+n`, `prefix+p`, and `prefix+1..9` still switch tabs while it's hidden
- Rebind it with `keys.toggle_tab_bar` under `[keys]`, e.g. `toggle_tab_bar = "prefix+y"`. `prefix+?` lists it under the sidebar keys

## 🟠⋯ Clear the screen
- ⌘K clears the focused pane's screen and scrollback, the same as in cmux. A shell gets a fresh prompt
- Full-screen programs like vim or an agent's TUI keep their screen and only get Ctrl+L, which usually redraws it
- If the pane is mid-way through printing an escape sequence, the clear waits for it to finish. Press ⌘K again to clear at once
- Turn it off with `clear_screen = ""` under `[keys]` in `~/.config/herdr/config.toml`, or rebind `keys.clear_screen`. `prefix+?` lists it
- If ⌘K does nothing, your terminal app is taking the key first. cmux passes it through. Ghostty on its own, kitty on macOS, iTerm2, and Terminal.app may bind ⌘K to their own clear: unbind it there, or rebind `keys.clear_screen`

## 🟠⋯ Agent names on attached tabs
- A window running `herdr terminal attach` shows its pane's title, status symbol included (`✳ my session`). cmux names the tab from it, so a tab showing a herdr-held agent reads the same as the agent running directly in cmux
- The name follows every change: renames, and the symbol while the agent works
- A pane with no title sends nothing, and the tab keeps the name its shell gave it. When a program clears its title, the tab keeps the last one
- Detaching doesn't bring back the tab's old name. Your shell's prompt renames it
- Turn it off with `window_title = ""` under `[ui]` in `~/.config/herdr/config.toml`. That also stops herdr setting the full view's window title
- Pane titles now survive an install (a live handoff), so `herdr pane list` keeps every name, and a tab that attaches again is named at once

# 🔵⋯ Install
## 🟠⋯ Install your fork build as your daily `herdr`
- From the herdr-rbf checkout, run `rbf/scripts/install-rbf.sh --dry-run`, read the plan, then run `rbf/scripts/install-rbf.sh`
- It builds whatever revision is checked out (`cargo build --release --locked`) and puts it at `~/.local/bin/herdr`. The binary it replaces is kept as `~/.local/bin/herdr.previous`
- Every running session is handed to the new build, and pane processes keep running, agents included. The session you typed the install into goes last
- Every attached `herdr` window closes during its session's handoff. Reattach with `herdr` for `default`, or `herdr session attach <name>`. The install prints each command, and panes redraw when a window reattaches
- `rbf/scripts/install-rbf.sh --rollback` swaps `herdr.previous` back in and hands off the same way. Run it again to undo the rollback
- Exit codes: `0` installed and every running session handed off; `1` nothing installed; `2` usage error; `3` installed, but at least one session wasn't handed off
- Each run logs to `~/Library/Logs/herdr-rbf-install.log`
- Needs the Rust toolchain from `rust-toolchain.toml`, Zig 0.16.0, `python3`, and `~/.local/bin` on `PATH` ahead of any other `herdr`

## 🟠⋯ `herdr update` is refused on fork builds
- `herdr update` and `herdr update --handoff` exit with `self-update is disabled for herdr-rbf builds` rather than swap your fork back to upstream's release
- The update notice still tells you when upstream ships a release, and names the install script, so you know to sync

# 🔵⋯ Versions
- This flavour's release version lives in `rbf/RBF_VERSION`, its history in `rbf/CHANGELOG.md`
- Upstream's own version file tracks upstream, not this flavour
