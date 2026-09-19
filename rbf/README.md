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

## 🟠⋯ Copy Codex replies without their display wrapping
- Drag across a Codex reply in herdr's full view and copy it to get the text Codex actually wrote: display-only wrap breaks and the reply gutter are removed, while Codex's own line breaks remain
- This applies only to reply prose and code. Prompts, command output, diffs, tool rows, Claude Code, and other agents copy exactly as drawn
- Run `herdr pane get <pane>` on the machine running the server and check that it shows `agent_session` with `"agent": "codex"`. If it doesn't, run `herdr integration install codex` on that machine and start the Codex pane again
- Herdr uses Codex's saved session reply as the authority. When it wanted that text and could not get it — no session hook, no session ID, an unreadable session file, or the lookup ran past its budget — it copies the rows as drawn and says `copied as shown · agent text unavailable`. It says the same when the rows match two saved replies differently, because joining would mean guessing
- Rows that match no saved reply are an ordinary copy, not a failure: command output, diffs and tool rows in a Codex pane copy as drawn and say `copied to clipboard`
- A successful reconstruction says how many wrapped lines it rejoined. Ordinary copies still say `copied to clipboard`
- To always copy the drawn rows, set `join_agent_wraps = false` under `[ui.copy]` in `~/.config/herdr/config.toml`, then run `herdr server reload-config` on that machine. For a remote pane, edit and reload the remote server's config

## 🟠⋯ Agent names on attached tabs
- A window running `herdr terminal attach` shows its pane's title, status symbol included (`✳ my session`). cmux names the tab from it, so a tab showing a herdr-held agent reads the same as the agent running directly in cmux
- The name follows every change: renames, and the symbol while the agent works
- A pane with no title sends nothing, and the tab keeps the name its shell gave it. When a program clears its title, the tab keeps the last one
- Detaching doesn't bring back the tab's old name. Your shell's prompt renames it
- Turn it off with `window_title = ""` under `[ui]` in `~/.config/herdr/config.toml`. That also stops herdr setting the full view's window title
- Pane titles now survive an install (a live handoff), so `herdr pane list` keeps every name, and a tab that attaches again is named at once

## 🟠⋯ Select and copy in attached agent tabs
- Ordinary mouse drag in an attached agent tab (`herdr terminal attach`, cmux tabs launched via `herdr-agent`) visibly highlights and copies text, while the mouse wheel continues scrolling Herdr's retained scrollback buffer
- Supported servers provide a one-pane semantic attach surface; older servers fall back to ANSI attachment with Shift-drag copy
- When `ui.copy_on_select` is false, Ctrl+C (or Cmd+C if forwarded) copies the retained selection
- If selected cells change during selection or the pane resizes, the selection clears with a notice: `selection changed · drag again`

## 🟠⋯ Agents that outlive the terminal (herdr-agent)
- Type `claude`, `codex`, `pi` or `agy` in a cmux tab and the agent runs inside this checkout's herdr session, shown in that tab. Closing the tab, or quitting or restarting cmux, doesn't stop it
- `herdr-agent ps` lists what runs, and `herdr-agent attach` shows one in any tab. For a second view, another tab or a phone over SSH, use `herdr session attach <session>`
- Resuming a session that's already running attaches to it instead of starting a second copy
- After a cmux restart, a tab that showed an agent, or ran `herdr --remote <host>`, shows it again. claude's status and notifications follow the tab showing it
- It installs with the fork (below) into `~/.local`, so it runs from the copy and not the checkout. It needs two blocks in `~/.zshenv` and one in `~/.zshrc`, given in `rbf/src/herdr-agent/share/herdr-agent/README.md`
- `herdr-agent status` says what's wired and what isn't; `herdr-agent off` and `on` are the switch

# 🔵⋯ Install
## 🟠⋯ Install your fork build as your daily `herdr`
- From the herdr-rbf checkout, run `rbf/scripts/install-rbf.sh --dry-run`, read the plan, then run `rbf/scripts/install-rbf.sh`
- It builds whatever revision is checked out (`cargo build --release --locked`) and puts it at `~/.local/bin/herdr`. The binary it replaces is kept as `~/.local/bin/herdr.previous`
- Every running session is handed to the new build, and pane processes keep running, agents included. The session you typed the install into goes last
- Every attached `herdr` window closes during its session's handoff. Reattach with `herdr` for `default`, or `herdr session attach <name>`. The install prints each command, and panes redraw when a window reattaches
- `rbf/scripts/install-rbf.sh --rollback` swaps `herdr.previous` back in and hands off the same way. Run it again to undo the rollback. It never touches herdr-agent
- The same run installs herdr-agent from `rbf/src/herdr-agent`, after `herdr` and before any handoff: the launcher at `~/.local/bin/herdr-agent`, the rest behind the link `~/.local/share/herdr-agent`. The copy it replaces is kept as `herdr-agent.previous`
- `rbf/scripts/install-rbf.sh --herdr-agent` installs herdr-agent alone, with no build and no handoff. `--herdr-agent --rollback` puts the previous herdr-agent back and leaves `herdr` and every session alone; run it again to return to the newer copy
- Exit codes: `0` installed, and every step after it finished; `1` nothing installed (with `--herdr-agent`, herdr-agent unchanged); `2` usage error; `3` installed, but a later step didn't finish: a session handoff, herdr-agent after `herdr`, cmux's restart entries, or keeping herdr-agent's rollback target
- Each run logs to `~/Library/Logs/herdr-rbf-install.log`
- Needs the Rust toolchain from `rust-toolchain.toml`, Zig 0.16.0, `python3`, and `~/.local/bin` on `PATH` ahead of any other `herdr`. herdr-agent's restart entries need `jq`

## 🟠⋯ `herdr update` is refused on fork builds
- `herdr update` and `herdr update --handoff` exit with `self-update is disabled for herdr-rbf builds` rather than swap your fork back to upstream's release
- The update notice still tells you when upstream ships a release, and names the install script, so you know to sync

# 🔵⋯ Versions
- This flavour's release version lives in `rbf/RBF_VERSION`, its history in `rbf/CHANGELOG.md`
- Upstream's own version file tracks upstream, not this flavour
