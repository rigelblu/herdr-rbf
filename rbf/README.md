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
- In a project folder, bare `herdr` opens this folder's herdr session, in a shell here: the session that holds the project's agents, in a tab called `shell`. Type it there again and you get the same shell back. `command herdr` is plain herdr for one call. `herdr-agent off` switches bare `herdr` back to plain herdr. `herdr --session default` still opens the old session
- Type `claude`, `codex`, `pi` or `agy` in a cmux tab and the agent runs inside this checkout's herdr session, shown in that tab. Closing the tab, or quitting or restarting cmux, doesn't stop it
- A running session is never removed. Once a session has stopped, after a reboot for example, herdr removes it 3 days after it was last in use — see "Sessions I've stopped using are removed" below
- `herdr-agent ps` lists what runs, and `herdr-agent attach` shows one in any tab. For a second view, another tab or a phone over SSH, use `herdr session attach <session>`
- Resuming a session that's already running attaches to it instead of starting a second copy
- After a cmux restart, a tab that showed an agent, or ran `herdr --remote <host>`, shows it again. claude's status and notifications follow the tab showing it
- It installs with the fork (below) into `~/.local`, so it runs from the copy and not the checkout. It needs two blocks in `~/.zshenv` and one in `~/.zshrc`, given in `rbf/src/herdr-agent/share/herdr-agent/README.md`
- `herdr-agent status` says what's wired and what isn't; `herdr-agent off` and `on` are the switch
- When an agent quits, the tab it was shown in keeps the agent's last 10 lines of output, as plain text, with herdr's line under them naming the agent and, when herdr knows it, its exit status. That holds for a normal quit too, so a resume command the agent prints stays on screen. An agent that dies at startup shows its real error the same way
- **Default session routing and reused servers**: By default, `herdr-agent` routes agent launches to the session for the current folder/repo root, reusing any server already running for that session. An install, live handoff, or launcher update does not alter the process context of an already running server. A server that outlives a macOS logout/login loses its macOS service context unless it was started by this launcher with the paired binary. If an existing server suffers from degraded or broken macOS service context (for example, failing default Keychain search list access or agent TLS/bootstrap errors), newly launched agents continue to inherit that existing server's context until the server is stopped and restarted.
- **Temporary routing to a healthy session**: While an existing session is in use or draining, you can route new agent launches to a separate, verified healthy named session using the environment override:
  ```bash
  HERDR_AGENT_SESSION=<healthy-session-name> <agent>
  ```
  Or export `HERDR_AGENT_SESSION=<healthy-session-name>` in the shell. This starts or attaches to that named session without modifying other running sessions.
- **Drain-first session migration**: To migrate an affected named session to a fresh server with verified persistent user service context:
  1. **Drain and save work first**: Finish active tasks and save editor files in all open panes.
  2. **Stop the server**: Run `herdr --session <session-name> server stop`. Stopping the server ends all active pane processes in that session.
  3. **Restart the session**: Launch an agent into that session from a healthy outer shell (for example, `HERDR_AGENT_SESSION=<session-name> <agent>`). The updated launcher verifies binary capability and starts a fresh server with the strict user context request. Stopping the server ends its pane processes; restart restores the workspace and tab layout with fresh shell processes.
  4. Never delete the session with `herdr session delete` during migration, or saved layout will be lost.
- **Paired install requirement**: Strict macOS context adoption requires both the capability-bearing Herdr binary (`herdr --capability macos-strict-user-context`) and the matching `herdr-agent` launcher. Run `rbf/scripts/install-rbf.sh` to install both together. Do not use `rbf/scripts/install-rbf.sh --herdr-agent` alone when updating for this fix: an older Herdr binary will fail the capability check, and the launcher will refuse to start new servers until `install-rbf.sh` installs the matching binary.

## 🟠⋯ Sessions I've stopped using are removed
- A stopped session other than `default` is removed 3 days after it was last in use. Nothing to run: any running herdr server does it, within a minute or two of the session passing the limit
- In use means a terminal window is showing the session, or an agent in it is `working` or `blocked`. Agent work counts: the 3 days start over each time an agent is `working` or `blocked`, so a session is still there 3 days after its agent finished
- Any other program left running in a session, a dev server or a build watcher, doesn't count as use
- Starting a session counts as using it. Stopping one doesn't, and neither does an install: a session keeps the time it was last in use across both
- A running session is never removed, and neither is `default`
- `herdr session list` deletes nothing. With no herdr server running, nothing is removed either: a stopped session past the limit stays in the list until a server has been up for two minutes
- A removed session can't be restored. herdr deletes its saved layout and what it resumes each agent from, and `herdr session attach <name>` then starts an empty session with that name. Each agent's own history still has its conversation, such as `claude --resume` in the project folder
- After a reboot, attach to a session within 3 days to keep it
- herdr keeps no record of a removal. The server that did it writes one line to its own log, and that is all
- Turn removal off with `remove_inactive_after_hours = 0` under `[session]` in `~/.config/herdr/config.toml`:
  ```toml
  [session]
  remove_inactive_after_hours = 0
  ```
- The same key changes the limit. It's in hours, the default is `72`, and decimals work: `1.5` is 90 minutes
- `inf` keeps every session too, and so does any value under `1`: the installed build treats a limit shorter than an hour as off
- A change needs no restart. Every running server reads the file again each minute: `0` takes effect within a minute, a new limit within two
- A value herdr can't read, or a config file that doesn't parse, turns removal off until it's fixed. A misspelled key is ignored and the default applies; `herdr config check` reports it
- A server started with `HERDR_CONFIG_PATH` reads the limit from that file
- After a rollback to a herdr older than 0.11.0, nothing is removed while it runs. At the next install a running session starts a fresh 3 days, and a stopped one the older herdr ran is aged by its newest file

# 🔵⋯ Install
## 🟠⋯ Install your fork build as your daily `herdr`
- From the herdr-rbf checkout, run `rbf/scripts/install-rbf.sh --dry-run`, read the plan, then run `rbf/scripts/install-rbf.sh`
- It builds whatever revision is checked out (`cargo build --release --locked`) and puts it at `~/.local/bin/herdr`. The binary it replaces is kept as `~/.local/bin/herdr.previous`
- Every running session is handed to the new build, and pane processes keep running, agents included. The session you typed the install into goes last
- Every attached `herdr` window closes during its session's handoff. Reattach with `herdr` for `default`, or `herdr session attach <name>`. The install prints each command, and panes redraw when a window reattaches
- `rbf/scripts/install-rbf.sh --rollback` swaps `herdr.previous` back in and hands off the same way. Run it again to undo the rollback. It never touches herdr-agent
- The same run installs herdr-agent from `rbf/src/herdr-agent`, after `herdr` and before any handoff: the launcher at `~/.local/bin/herdr-agent`, the rest behind the link `~/.local/share/herdr-agent`. The copy it replaces is kept as `herdr-agent.previous`
- `rbf/scripts/install-rbf.sh --herdr-agent` installs herdr-agent alone, with no build and no handoff. `--herdr-agent --rollback` puts the previous herdr-agent back and leaves `herdr` and every session alone; run it again to return to the newer copy (note: on macOS, fresh server starts require a paired capability-bearing `herdr` binary from a full `install-rbf.sh` run; the launcher will refuse to start servers if paired with an older binary)
- Exit codes: `0` installed, and every step after it finished; `1` nothing installed (with `--herdr-agent`, herdr-agent unchanged); `2` usage error; `3` installed, but a later step didn't finish: a session handoff, herdr-agent after `herdr`, cmux's restart entries, or keeping herdr-agent's rollback target
- Each run logs to `~/Library/Logs/herdr-rbf-install.log`
- Needs the Rust toolchain from `rust-toolchain.toml`, Zig 0.16.0, `python3`, and `~/.local/bin` on `PATH` ahead of any other `herdr`. herdr-agent's restart entries need `jq`

## 🟠⋯ `herdr update` is refused on fork builds
- `herdr update` and `herdr update --handoff` exit with `self-update is disabled for herdr-rbf builds` rather than swap your fork back to upstream's release
- The update notice still tells you when upstream ships a release, and names the install script, so you know to sync

# 🔵⋯ Sync with upstream
## 🟠⋯ Bring upstream Herdr into the fork
- `rbf/scripts/upstream-sync.sh` moves the fork forward from Herdr's upstream `master` one checked step at a time: `check` → `stage <receipt>` → `inspect <receipt>` → `integrate <receipt>` → resolve by hand → `finish <receipt>`. Nothing is pushed, installed, or released — the workflow stops at a verified local `master`
- Once per clone, make local `master` track `master@origin` so it names the fork and not upstream (`check` refuses and prints these same four lines until they've run):
  ```
  jj bookmark untrack master@upstream
  jj bookmark set master -r master@origin --allow-backwards
  jj bookmark track master@origin
  jj config set --repo 'revset-aliases."immutable_heads()"' 'builtin_immutable_heads() | remote_bookmarks(remote=exact:"origin")'
  ```
- Fold any work above the fork tip under `master` before running `check`: commit it as its own change, then `jj bookmark set master -r <that change>`. A commit between `check` and `stage` also advances the operation log, which `stage` refuses
- Make an isolated task worktree for resolving conflicts in, e.g. `jj workspace add <path> -r master` (its `@` is an empty child of `master`, which moves along with the stack), and run `stage` → `inspect` → `integrate` from that same worktree
- `check` fetches `upstream`, reports the divergence (source and upstream tips, merge base, fork stack size, bookmarks that will move), and writes a receipt at `${XDG_STATE_HOME:-$HOME/.local/state}/herdr-rbf-upstream-sync/<run-id>.receipt` (override the directory with `UPSTREAM_SYNC_STATE_DIR`, the branch with `UPSTREAM_BRANCH`, default `master`). `<receipt>` in every later command is that path or just the run ID it prints (e.g. `20260922-1412`). It refuses while the source range already holds conflicts, or while no upstream remote or branch is configured
- `stage <receipt>` rebases the fork stack as a detached jj operation — your live checkout, its bookmarks, and the active operation don't move. It refuses if any non-empty revision outside the fork stack would be rewritten, naming it, and creates nothing when it refuses
- `inspect <receipt>` reads that detached operation without changing anything: the rebased stack, a conflict ledger (each change's own conflict regions, by path — a region a change inherits from a lower change isn't counted again), and a carried/empty/missing preview of every fork change
- `integrate <receipt>` applies exactly that operation, refusing if the repository moved since `stage`. jj carries `master` and every other local bookmark on the stack to the rebased tip, so between `integrate` and `finish`, `master` names an unverified tree — don't install or release from it. Other workspaces go stale; `jj workspace update-stale` there catches them up. If conflicts remain, `integrate` prints the bottom-up resolve recipe, flagging any fork-owned, deleted/renamed, or otherwise unusual conflict next to its path — a plain upstream-file edit isn't auto-resolved either, just unflagged
- Resolve each conflicted change bottom-up, lowest first: `jj new <change>` → edit (upstream's code, with the fork's change on top) → `jj squash --from '<change>..@' --into <change>`. Then `jj new master` so the checkout is `master` again
- `finish <receipt> --verify-cmd <cmd>` (or set `UPSTREAM_SYNC_VERIFY_CMD`) refuses remaining conflicts, a checkout that isn't `master` or its empty child, and a missing verify command. It walks the receipt's change map and refuses unless every fork change is carried or empty; a change no longer found needs `--dropped <change-id>` to record that the drop was deliberate — repeat the flag for more than one, and a rerun remembers past drops. Only then does it run `<cmd>`, streaming its output, and only if that exits zero does it record the receipt `verified-local-master` and print `✓ verified local master; master@origin unchanged at <id>`. It writes no bookmark: `master` already names the rebased tip, jj having carried it there at `integrate`. `--skip-verify` doesn't exist — `finish` has no bypass
- Recover before integrating by leaving the detached operation unintegrated and running `check` again — same for any refusal naming a stale operation. After integrating, fix and rerun `finish`; to abandon the whole sync, `jj op restore <pre-op>`, only after confirming `jj op log` shows no unrelated operation since
- `rbf/scripts/verify-fork.sh` is the fork's own full check, and today's `--verify-cmd`: `just ci`, `just docs-contract-test`, and this fork's own harnesses (`upstream-sync.test.sh`, every `install-rbf.test.sh` case but `real-agent`, which needs a logged-in `claude` first). It builds the release binary once, needs `RBF_TEST_ROOT` or `EXTERNAL_DRIVE` for the harnesses' scratch root, and turns `tag.gpgsign` off for the run. `just check` would stop at `windows-lint`, which this Mac can't run
- Run `stage` → `inspect` → `integrate` back to back, with no other session editing herdr-rbf meanwhile: any jj operation in between makes them refuse, and the way back is a fresh `check`
- After `finish`, the tree carries upstream's commits while `rbf/RBF_VERSION` is unchanged — it stays unreleased until a separate `deliver-feat`, which re-runs each carried feature's own human checks before its build replaces the installed one
- **If it doesn't work:** `✗ 1 fork change is missing` → bring it back from `jj op log`, or rerun `finish` with `--dropped <change>` if it was dropped on purpose; `✗ no upstream remote` → `git remote add upstream git@github.com:herdrdev/herdr.git`; `✗ master tracks master@upstream` → run the one-time fix above; any `✗` naming an operation ID → run `check` again for a fresh receipt

# 🔵⋯ Versions
- This flavour's release version lives in `rbf/RBF_VERSION`, its history in `rbf/CHANGELOG.md`
- Upstream's own version file tracks upstream, not this flavour
