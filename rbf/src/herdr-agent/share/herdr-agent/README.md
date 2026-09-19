# herdr-agent

Runs my agent TUIs — claude, codex, pi, agy — inside `herdr`, one session per checkout, so they
survive cmux closing and I can reach them from my phone. cmux stays the UI.

Start an agent the way I always do. In a cmux tab it lands in herdr instead of the tab itself.

    claude              # runs in herdr, shown in this tab
    herdr-agent ps      # what's running, and where
    herdr-agent attach  # show one of them in this tab
    herdr-agent status  # what's wired, and what isn't
    herdr-agent check   # the self-check; --with-claude adds the one live case it skips

Ctrl+B then q detaches and leaves the agent running. Ctrl+B Ctrl+B sends a literal Ctrl+B.

## The two notes

Both are written by `attach()`, and they point opposite ways.

| Note | Path | Answers |
| --- | --- | --- |
| tab → pane | `$state_dir/tabs/<surface>` | which pane to show when cmux restarts this tab |
| pane → tab | `$state_dir/panes/<session>.<pane>` | which tab an agent's hooks should reach now |

`$state_dir` is `$XDG_STATE_HOME/herdr-agent`, else `~/.local/state/herdr-agent`. The pane note
is three tab-separated fields: `<surface>\t<workspace>\t<attach pid>`. The tab note has two
shapes, both tab-separated. A local one is `<session>\t<pane>\t<agent>\t<agent session>`. A
remote one is the herdr arguments the tab ran, starting with `--remote`. No herdr session can
be named `--remote`, so the two can't be confused.

## Remote herdr tabs

`herdr --remote <host>` in a cmux tab comes back after a cmux restart, like a local one:

- the `herdr` function in `.zshrc` sends `herdr --remote …` to `herdr-agent attach --remote …`,
  but only in a cmux tab and only when `--remote` is the first argument. Every other herdr call
  runs as is
- the launcher notes the arguments against the tab, then runs herdr under the name
  `herdr-agent-attach` with `--remote` first
- cmux's `herdr-agent-attach-remote` restart entry matches that name plus `--remote`, and after
  a restart runs `herdr-agent attach --restore`, which reruns the noted arguments
- the local entry matches the same name with `--session` first, so no process matches both.
  cmux accepts two entries with one process name when something else tells them apart

Switched off (`herdr-agent off`), inside herdr, or outside a cmux tab, it's plain herdr and
nothing is noted.

What it can't do:

- **bring status back.** Agents on the remote machine send their hooks to that machine's
  cmux, if any, never this one
- **reach a host that's gone.** If the host is unreachable after a restart, ssh's error shows
  once and the tab drops to its shell. cmux runs a restart command only once, so nothing retries

Every attach rewrites the pane note, so it tracks the tab live.

## Why the shim exists

An agent's environment is fixed when it starts. Its hooks keep naming the tab it started in and
the attach process that was alive then. Move the pane to another tab and those hooks aim at a
closed tab and a dead process.

`hook-cmux` stands in for cmux in the agent's hooks. It reads the pane note, rewrites
`CMUX_SURFACE_ID`, `CMUX_WORKSPACE_ID` and the agent's pid variable, then `exec`s the real cmux.
Anything missing or stale, it runs cmux unchanged — a hook never fails because of us.

**cmux treats what we export as a claim, not an answer.** It verifies the surface against
`surface.list` for the workspace, and falls through to the pid's terminal — which it calls ground
truth — when that fails. So the pid export is what actually saves a moved pane: the surface claim
often fails, because the note's workspace goes stale the moment a tab is moved between workspaces.

Hooks arrive in two shapes, and both have to be recognised:

    cmux [--socket …] hooks <agent> <event>
    cmux [--socket …] hooks feed --source <agent>

claude sends 9 of the first and 3 of the second. Matching only the first leaves a quarter of its
hooks unrouted, carrying the dead pid.

## What can be routed, and what can't

Only claude. The rest were each traced to cmux's own source and the installed wrappers — none of
this is inferred from behaviour.

| Agent | Routed | Why |
| --- | --- | --- |
| claude | yes | its hooks call `"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}"`, which we set |
| codex | no | `cmux-codex-wrapper` overwrites `CMUX_CODEX_HOOK_CMUX_BIN` at launch, and the hook it injects resolves cmux from `CMUX_BUNDLED_CLI_PATH` or `$PATH` and never reads that variable |
| pi | no | its hooks carry `--surface`/`--workspace` built from pi's own environment, and an explicit flag beats anything we export; it also spawns hooks through an allowlist that drops every `HERDR_*` |
| agy | no | its hook in `~/.gemini/config/hooks.json` hardcodes cmux's absolute path, and cmux regenerates that file |

So codex, pi and agy keep their status on the tab they started in. That is a limitation, not a bug
to go fix — each was tried and each has a named reason.

**The one untried lever** is `CMUX_BUNDLED_CLI_PATH`: codex's injected hook reads it, so pointing
it at the shim would route codex. Don't, without reading this first.

The shim refuses to exec itself, so the lever no longer produces an endless exec loop — it falls
through to whatever `cmux` is on `$PATH`. The rest of the blast radius stands. That variable also
feeds `cmux-codex-wrapper`'s `CMUX_INJECT_CLI`, which it runs to emit codex's hook arguments, and
the wrapper treats an empty result as "leave codex alone":

> If the emit fails or yields nothing, we fall back to the original argv so installing the
> wrapper can never break codex.

So a shim that comes back empty there doesn't error — it silently strips codex's cmux hooks
entirely. For a cosmetic gain on an agent that already runs and survives, it isn't worth it.

`CMUX_PI_PID` is read nowhere in cmux. If you find yourself adding it back for symmetry, don't.

## One tab per agent, and seeing it in two places

`herdr-agent attach` runs `herdr terminal attach`, a direct client, and herdr allows one per
pane (`headless.rs:1830` in herdr-rbf). A second one fails unless it passes `--takeover`, which
disconnects the first. So the launcher's re-attaches take over: the choice herdr offers is
take over or fail, never share.

My guess at why herdr allows only one: a direct client sizes the pane to its own terminal and
locks it there. A pane is one pseudo-terminal with one size.

herdr's full view (`herdr session attach <session>`) is the other kind of client. Any number
can run, and none of them can disconnect the tab's direct client. So it's the way to see an
agent in a second place, like another tab or a phone. It shows the agent, but its
notifications keep following the tab `herdr-agent attach` wrote the pane note for.

## Not built yet

- **`herdr-agent view [session pane]`**: open herdr's full view already on an agent's pane,
  so a second place to see it is one command instead of `herdr session attach` and then
  finding the pane. It's an idea for later (2026-09-18): build it once opening a second view
  becomes a habit. Two questions to settle first: can the full view open on a given pane,
  and should a second view get notifications too? Today only the tab with the pane note
  does.

## Verifying it

`herdr-agent check` covers the shim in isolation and the launcher wiring, and mutation-testing
each case is the habit worth keeping — a green test here proved nothing twice before.

What the check can't reach is delivery: whether cmux accepts what the shim hands it. That needs a
person:

1. Start a throwaway agent in a cmux tab (`claude --model haiku`), name the tab, prompt it, and
   confirm the notification lands — the control
2. Detach with Ctrl+B q, close the tab
3. Open a new tab, `herdr-agent attach`, pick that pane. It must be this command; attaching
   through `herdr` directly skips the note
4. Confirm the pane note now names the new tab, while the agent's own environment still names the
   closed one — that divergence is the thing under test
5. Prompt it again and switch away. The notification should land on the new tab

An agent started before the shim existed keeps its old routing until it's restarted.
