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

# 🔵⋯ Versions
- This flavour's release version lives in `rbf/RBF_VERSION`, its history in `rbf/CHANGELOG.md`
- Upstream's own version file tracks upstream, not this flavour
