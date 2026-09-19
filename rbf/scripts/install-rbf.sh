#!/bin/bash

# Build the checked-out herdr-rbf revision and install it as the daily `herdr`,
# handing every running session to the new build so pane processes keep running.
# The same run installs herdr-agent from rbf/src/herdr-agent; --herdr-agent installs
# it alone, with no build and no handoff.
#
# The binary lands at ~/.local/bin/herdr by one same-volume rename, and the
# outgoing binary is kept as ~/.local/bin/herdr.previous for --rollback.
# The session hosting this terminal is handed off last, because handoff closes
# every attached window.
#
# herdr-agent lands in two parts, whose paths are the contract: the launcher at
# ~/.local/bin/herdr-agent (a regular file), and its tree behind the link
# ~/.local/share/herdr-agent -> herdr-agent@<time>.<unique>. The link is exchanged in
# one call and the launcher renamed, with signals ignored across both; the outgoing
# launcher and tree link become herdr-agent.previous only after both steps succeed,
# kept as they were (a link stays a link). --herdr-agent --rollback exchanges current
# and previous.
#
# bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile; python3 parses JSON.
#
# Test seams:
#   RBF_INSTALL_PREBUILT=<path>  install that file instead of building
#   RBF_INSTALL_CARGO=<cmd>      build command (default: cargo; not CARGO, which cargo
#                                itself exports to child processes)
#   RBF_INSTALL_SOURCE_ONLY=1    define the functions and return without running
#   RBF_INSTALL_HERDR_AGENT_SRC=<dir>
#                                install herdr-agent from that tree instead of
#                                rbf/src/herdr-agent
#   RBF_INSTALL_HERDR_AGENT_PAUSE=<point>:<seconds>
#                                sleep at one point so a test can signal there: staged
#                                (signals live), prepared (signals live), renames
#                                (between the two renames, signals ignored)
#   RBF_INSTALL_HERDR_AGENT_FAIL=<rename2|rename3|rename4>
#                                make that rename of the herdr-agent swap fail

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN_DIR="$HOME/.local/bin"
TARGET="$BIN_DIR/herdr"
PREVIOUS="$BIN_DIR/herdr.previous"
LOG="$HOME/Library/Logs/herdr-rbf-install.log"
HOSTING_SOCKET="${HERDR_SOCKET_PATH:-}"
PING_TIMEOUT=2
STAGED=""
PREVIOUS_COPY=""

SHARE_DIR="$HOME/.local/share"
HA_BIN="$BIN_DIR/herdr-agent"
HA_PREV="$BIN_DIR/herdr-agent.previous"
HA_SHARE="$SHARE_DIR/herdr-agent"
HA_SHARE_PREV="$SHARE_DIR/herdr-agent.previous"
HA_SRC="${RBF_INSTALL_HERDR_AGENT_SRC:-$REPO/rbf/src/herdr-agent}"
HA_LINK_TARGET="../../../bin/herdr-agent"
HA_AGENTS="claude codex pi agy"
# This run's temporary files: the stage (tree and launcher), the prepared outgoing
# copies (the new share link is made under the prevlink name). Every exit before the swap
# removes them
HA_STAGE_TREE=""
HA_STAGE_BIN=""
HA_PREP_BIN=""
HA_PREP_LINK=""
HA_INTERRUPTED=0

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/install-rbf.sh [--herdr-agent] [--dry-run | --rollback]

Build the checked-out herdr-rbf revision, install it as ~/.local/bin/herdr, and
hand every running session to it. Pane processes keep running; every attached
herdr window closes and reattaches with `herdr session attach <name>`.
The same run installs herdr-agent from rbf/src/herdr-agent.

Options:
  --herdr-agent  Install only herdr-agent: no build, no herdr, no handoff.
                 With --rollback, restore only herdr-agent.previous.
  --dry-run      Print the plan; build nothing, write nothing, touch no session.
  --rollback     Swap herdr.previous back in and hand off the same way.
                 herdr-agent isn't touched; use --herdr-agent --rollback.
  -h, --help     Show this help.

Exit codes:
  0  installed, and every step after it finished
  1  nothing installed (build failed, or no usable herdr.previous);
     with --herdr-agent, herdr-agent unchanged
  2  usage error
  3  installed, but a later step didn't finish: a session handoff,
     herdr-agent after herdr, cmux's restart entries, or keeping
     herdr-agent's rollback target

Log: ~/Library/Logs/herdr-rbf-install.log
USAGE
}

say() { printf '%s\n' "$*" >&2; }

log_line() {
  mkdir -p "$(dirname "$LOG")" 2>/dev/null
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$LOG" 2>/dev/null
}

finish() {
  log_line "exit $1"
  exit "$1"
}

cleanup_staged() {
  [ -n "$STAGED" ] && rm -f "$STAGED"
  [ -n "$PREVIOUS_COPY" ] && rm -f "$PREVIOUS_COPY"
  ha_cleanup
}

# interrupted <code>: INT or TERM keeps the exit-code contract and the log's exit line
interrupted() {
  if [ "$1" = 1 ]; then
    say "✗ interrupted; nothing was written to ~/.local/bin"
  else
    say "⚠ interrupted during handoffs; rerun the install to hand off every session"
  fi
  finish "$1"
}

# Every herdr call clears the pane's socket overrides and names its session,
# so it can only reach the session it means to.
herdr_call() {
  local bin="$1"
  shift
  env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_SESSION "$bin" "$@"
}

reattach_command() {
  if [ "$1" = default ]; then
    printf 'herdr'
  else
    printf 'herdr session attach %s' "$1"
  fi
}

rbf_version() {
  tr -d '[:space:]' < "$REPO/rbf/RBF_VERSION" 2>/dev/null || printf 'unknown'
}

revision() {
  local id
  id="$(jj -R "$REPO" --ignore-working-copy log -r @ --no-graph -T 'change_id.short(12)' 2>/dev/null)"
  if [ -n "$id" ]; then
    printf '%s (jj working copy)' "$id"
  else
    printf 'unknown'
  fi
}

revision_id() {
  local id
  id="$(jj -R "$REPO" --ignore-working-copy log -r @ --no-graph -T 'change_id.short(12)' 2>/dev/null)"
  printf '%s' "${id:-unknown}"
}

# Running sessions as "name<TAB>socket_path" lines, the hosting session last.
list_sessions() {
  local bin="$1"
  herdr_call "$bin" session list --json 2>/dev/null | python3 -c '
import json, sys
hosting = sys.argv[1]
try:
    sessions = json.load(sys.stdin).get("sessions", [])
except Exception:
    sys.exit(1)
running = [s for s in sessions if s.get("running")]
ordered = [s for s in running if s.get("socket_path") != hosting] + [s for s in running if s.get("socket_path") == hosting]
for s in ordered:
    print("%s\t%s" % (s["name"], s["socket_path"]))
' "$HOSTING_SOCKET"
}

# Exit 0 when the server behind the socket answers a ping within PING_TIMEOUT seconds.
ping_socket() {
  python3 - "$1" "$PING_TIMEOUT" <<'PY'
import socket, sys
path, timeout = sys.argv[1], float(sys.argv[2])
try:
    c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    c.settimeout(timeout)
    c.connect(path)
    c.sendall(b'{"id":"rbf:ping","method":"ping","params":{}}\n')
    reply = b""
    while not reply.endswith(b"\n"):
        chunk = c.recv(65536)
        if not chunk:
            break
        reply += chunk
    sys.exit(0 if b'"rbf:ping"' in reply else 1)
except Exception:
    sys.exit(1)
PY
}

# classify_handoff <rc> <socket> → handed-off | kept | none
classify_handoff() {
  if ! ping_socket "$2"; then
    printf 'none\n'
  elif [ "$1" -eq 0 ]; then
    printf 'handed-off\n'
  else
    printf 'kept\n'
  fi
}

handoff_error() {
  printf '%s' "$1" | python3 -c '
import json, sys
text = sys.stdin.read().strip()
for line in text.splitlines():
    try:
        print(json.loads(line)["error"]["message"])
        sys.exit(0)
    except Exception:
        pass
print(text.splitlines()[-1] if text else "no output")
'
}

# The first herdr on PATH, when it isn't the one this script installs.
path_shadow() {
  local first first_dir
  first="$(type -P herdr 2>/dev/null)"
  [ -n "$first" ] || return 0
  first_dir="$(cd "$(dirname "$first")" 2>/dev/null && pwd -P)"
  if [ "$first_dir" != "$(cd "$BIN_DIR" 2>/dev/null && pwd -P)" ]; then
    printf '%s' "$first"
  fi
}

bin_dir_on_path() {
  local dir bin_physical IFS=:
  bin_physical="$(cd "$BIN_DIR" 2>/dev/null && pwd -P)"
  for dir in $PATH; do
    [ "$dir" = "$BIN_DIR" ] && return 0
    [ -n "$bin_physical" ] && [ "$(cd "$dir" 2>/dev/null && pwd -P)" = "$bin_physical" ] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# herdr-agent
# ---------------------------------------------------------------------------

# The source as the plan and step lines name it: relative to the checkout, or the
# seam's path as given
ha_src_label() {
  if [ -n "${RBF_INSTALL_HERDR_AGENT_SRC:-}" ]; then
    printf '%s' "$RBF_INSTALL_HERDR_AGENT_SRC"
  else
    printf 'rbf/src/herdr-agent'
  fi
}

ha_src_ok() { [ -f "$HA_SRC/bin/herdr-agent" ] && [ -d "$HA_SRC/share/herdr-agent" ]; }

# Every entry under a tree, one line each: type, path, mode, and a link's target or a
# file's checksum. Two trees with the same lines hold the same bytes, links and modes
ha_tree_shape() {
  (
    cd "$1" 2>/dev/null || exit 1
    find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r f; do
      if [ -L "$f" ]; then
        printf 'L %s %s\n' "$f" "$(readlink "$f")"
      elif [ -d "$f" ]; then
        printf 'D %s %s\n' "$f" "$(stat -f '%p' "$f")"
      else
        printf 'F %s %s %s\n' "$f" "$(stat -f '%p' "$f")" "$(shasum -a 256 < "$f")"
      fi
    done
  )
}

# ha_same_as_installed <launcher> <tree>: that launcher and tree are what's installed,
# byte for byte, with the launcher a regular file and the tree behind the share link
ha_same_as_installed() {
  [ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ] && [ -L "$HA_SHARE" ] || return 1
  cmp -s "$1" "$HA_BIN" || return 1
  local a b
  a="$(ha_tree_shape "$2")" || return 1
  b="$(ha_tree_shape "$HA_SHARE/")" || return 1
  [ "$a" = "$b" ]
}

# The share path holds something this installer didn't make: a real directory or file
ha_share_foreign() { [ -e "$HA_SHARE" ] && [ ! -L "$HA_SHARE" ]; }

ha_have_previous() { [ -e "$HA_PREV" ] || [ -L "$HA_PREV" ]; }

# present | missing | nojq: cmux's restart entries, as the launcher at $1 defines them
ha_restart_state() {
  command -v jq > /dev/null 2>&1 || { printf 'nojq'; return; }
  if /bin/zsh -f -c '0=$1; eval "$(sed "/^case \\\$invoked in/,\$d" "$1")"; restart_entry_installed' \
    ha "$1" > /dev/null 2>&1; then
    printf 'present'
  else
    printf 'missing'
  fi
}

ha_plan_cmux_row() {
  case "$(ha_restart_state "$1")" in
    present) say "                 cmux      restart entries present" ;;
    missing) say "                 cmux      will add restart entries; cmux asks to approve" ;;
    nojq) say "                 cmux      can't check: jq not found" ;;
  esac
}

# The herdr-agent sub-block of an install plan
ha_plan_install() {
  if ! ha_src_ok; then
    say "  herdr-agent    from      $(ha_src_label) (not found)"
    return
  fi
  if ha_same_as_installed "$HA_SRC/bin/herdr-agent" "$HA_SRC/share/herdr-agent"; then
    say "  herdr-agent    same as installed; nothing to change"
  else
    say "  herdr-agent    from      $(ha_src_label)"
    say "                 to        $HA_BIN"
    say "                           $HA_SHARE"
    if [ -L "$HA_BIN" ]; then
      say "                 previous  kept as herdr-agent.previous (a link, as it is now)"
    elif [ -e "$HA_BIN" ]; then
      say "                 previous  kept as herdr-agent.previous"
    else
      say "                 previous  none (first install)"
    fi
  fi
  ha_plan_cmux_row "$HA_SRC/bin/herdr-agent"
}

# The herdr-agent sub-block of a --herdr-agent --rollback plan
ha_plan_rollback() {
  if ! ha_have_previous; then
    say "  herdr-agent    from      nothing: no herdr-agent.previous"
  elif [ -L "$HA_PREV" ]; then
    say "  herdr-agent    from      herdr-agent.previous, a link to"
    say "                           $(readlink "$HA_PREV")"
    say "                 to        $HA_BIN"
    say "                 support   the files beside that link's target"
    say "                 previous  the current one, kept as herdr-agent.previous"
  else
    say "  herdr-agent    from      herdr-agent.previous"
    say "                 to        $HA_BIN"
    say "                           $HA_SHARE"
    say "                 previous  the current one, kept as herdr-agent.previous"
  fi
}

# Removes whatever of this run's stage and prepared copies still exist
ha_cleanup() {
  [ -n "$HA_STAGE_TREE" ] && rm -rf "$HA_STAGE_TREE"
  [ -n "$HA_STAGE_BIN" ] && rm -f "$HA_STAGE_BIN"
  [ -n "$HA_PREP_BIN" ] && rm -f "$HA_PREP_BIN"
  [ -n "$HA_PREP_LINK" ] && rm -f "$HA_PREP_LINK"
  HA_STAGE_TREE="" HA_STAGE_BIN="" HA_PREP_BIN="" HA_PREP_LINK=""
}

# ha_pause <point>: the RBF_INSTALL_HERDR_AGENT_PAUSE seam. The sleep runs in the
# background so a live signal's handler runs at once, not after the sleep
ha_pause() {
  local seam="${RBF_INSTALL_HERDR_AGENT_PAUSE:-}"
  [ "${seam%%:*}" = "$1" ] || return 0
  local pid
  sleep "${seam#*:}" &
  pid=$!
  wait "$pid" 2> /dev/null
  kill "$pid" 2> /dev/null
  return 0
}

# ha_mv <step> <mv args...>: /bin/mv, unless RBF_INSTALL_HERDR_AGENT_FAIL names this step
ha_mv() {
  local step="$1"
  shift
  [ "${RBF_INSTALL_HERDR_AGENT_FAIL:-}" = "$step" ] && return 1
  /bin/mv "$@"
}

# The first line of a tool's complaint, with the stage's path trimmed to the name
# inside the tree
ha_reason() {
  printf '%s\n' "$1" | head -1 | sed -e "s|$HA_STAGE_BIN|herdr-agent|g" -e "s|$HA_STAGE_TREE/||g"
}

# ha_fail <glyph> <line> [reason]: a refusal before the swap; this run's stage and
# prepared copies are removed
ha_fail() {
  ha_cleanup
  say "$1 $2"
  [ -n "${3:-}" ] && say "  $3"
  log_line "herdr-agent refused: $2"
}

# In a plain install an interrupt while herdr-agent stages is recorded, and herdr-agent
# abandons at its next step, so the sessions are still handed off
ha_record_interrupt() { HA_INTERRUPTED=1; }

# With --herdr-agent, an interrupt before the swap leaves herdr-agent unchanged
ha_interrupted_only() {
  ha_cleanup
  say "✗ interrupted; herdr-agent unchanged"
  finish 1
}

# After herdr-agent is in, an interrupt leaves the restart entries unchecked
ha_interrupted_installed() {
  say "⚠ interrupted; herdr-agent is installed, cmux restart entries not checked"
  finish 3
}

# ha_abandoned: in a plain install, whether an interrupt arrived; if so the stage goes
ha_abandoned() {
  [ "$HA_INTERRUPTED" = 1 ] || return 1
  ha_cleanup
  say "✗ interrupted; herdr is installed, herdr-agent unchanged"
  log_line "herdr-agent interrupted"
  return 0
}

# swap_in_herdr_agent <glyph>: stage, smoke-test, and swap herdr-agent in. <glyph> is
# ✗ with --herdr-agent (a refusal ends the run) and ⚠ in a plain install (it goes on).
# Sets HA_RESULT: installed | kept-old (installed, rollback target not updated) |
# same | refused | interrupted. Returns 0 when herdr-agent is installed or unchanged
swap_in_herdr_agent() {
  local g="$1" src_label stamp tree new_name out a target rc
  src_label="$(ha_src_label)"
  HA_RESULT=refused
  say "⋯ staging herdr-agent"

  if ! ha_src_ok; then
    ha_fail "$g" "no herdr-agent at $src_label; herdr-agent unchanged"
    return 1
  fi
  if ha_share_foreign; then
    # shellcheck disable=SC2088  # a path shown to the user, not expanded
    ha_fail "$g" "~/.local/share/herdr-agent is a directory this installer didn't make; herdr-agent unchanged" \
      "move it aside, then rerun"
    return 1
  fi

  # stage: a tree under a name no other run can have, and the launcher beside its target
  stamp="$(date +%Y%m%d-%H%M%S)"
  if ! mkdir -p "$BIN_DIR" "$SHARE_DIR" ||
    ! tree="$(mktemp -d "$SHARE_DIR/herdr-agent@$stamp.XXXX")"; then
    ha_fail "$g" "couldn't stage $src_label; herdr-agent unchanged"
    return 1
  fi
  HA_STAGE_TREE="$tree"
  HA_STAGE_BIN="$BIN_DIR/.herdr-agent.staged.$$"
  if ! chmod 755 "$tree" || ! /bin/cp -pR "$HA_SRC/share/herdr-agent/." "$tree/" ||
    ! /bin/cp -p "$HA_SRC/bin/herdr-agent" "$HA_STAGE_BIN"; then
    ha_fail "$g" "couldn't stage $src_label; herdr-agent unchanged"
    return 1
  fi
  ha_pause staged
  ha_abandoned && { HA_RESULT=interrupted; return 1; }

  # smoke: what runs on every launch and every claude hook has to parse and run
  if ! out="$(/bin/zsh -n "$HA_STAGE_BIN" 2>&1)"; then
    ha_fail "$g" "staged herdr-agent doesn't parse; herdr-agent unchanged" "$(ha_reason "$out")"
    return 1
  fi
  if ! out="$(/bin/zsh -n "$tree/hook-cmux" 2>&1)"; then
    ha_fail "$g" "staged hook-cmux doesn't parse; herdr-agent unchanged" "$(ha_reason "$out")"
    return 1
  fi
  "$HA_STAGE_BIN" --help > /dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    ha_fail "$g" "staged herdr-agent --help exited $rc; herdr-agent unchanged"
    return 1
  fi
  for a in $HA_AGENTS; do
    target="$(readlink "$tree/bin/$a" 2>/dev/null)"
    if [ "$target" != "$HA_LINK_TARGET" ]; then
      ha_fail "$g" "staged bin/$a points at ${target:-nothing}, not $HA_LINK_TARGET; herdr-agent unchanged"
      return 1
    fi
  done
  ha_abandoned && { HA_RESULT=interrupted; return 1; }

  # same? the same copy twice keeps .previous where it is
  if ha_same_as_installed "$HA_STAGE_BIN" "$tree"; then
    ha_cleanup
    HA_RESULT=same
    say "✓ herdr-agent unchanged (same as installed)"
    return 0
  fi

  new_name="$(basename "$tree")"
  ha_exchange "$g" "$HA_STAGE_BIN" "$new_name" "couldn't replace ~/.local/bin/herdr-agent; herdr-agent unchanged"
  case $? in
    1) return 1 ;;
    2) HA_RESULT=interrupted; return 1 ;;
  esac
  HA_RESULT=installed
  log_line "installed herdr-agent $new_name"
  say "✓ installed herdr-agent (rbf $(rbf_version), $(revision_id))"
  case "$HA_KEPT" in
    pair) ha_prune ;;
    older)
      HA_RESULT="kept-old"
      say "⚠ couldn't keep the previous herdr-agent as herdr-agent.previous"
      say "  --herdr-agent --rollback would restore the older herdr-agent.previous, not the one just replaced"
      log_line "herdr-agent.previous not updated"
      ;;
    none)
      HA_RESULT="kept-old"
      say "⚠ couldn't keep the previous herdr-agent; rollback target removed"
      say "  --herdr-agent --rollback has nothing to restore until the next install"
      log_line "herdr-agent.previous removed: its tree link couldn't be kept"
      ;;
  esac
  return 0
}

# ha_swap_links <a> <b>: exchange two paths in one call, renamex_np(RENAME_SWAP).
# Renaming a link over a link leaves a moment in which neither exists (APFS; measured
# 2026-09-19), and every launch and claude hook resolves through ~/.local/share/herdr-agent.
# A file renamed over a file has no such moment, so the launcher keeps a plain rename
ha_swap_links() {
  python3 -c 'import ctypes, sys
libc = ctypes.CDLL(None, use_errno=True)
sys.exit(0 if libc.renamex_np(sys.argv[1].encode(), sys.argv[2].encode(), 2) == 0 else 1)' "$1" "$2"
}

# ha_exchange <glyph> <new launcher> <new tree name | ""> <step-2 refusal>: the swap that
# install and rollback share. The outgoing launcher and tree link are copied aside; then,
# with signals ignored, the share link moves to <new tree name> (left alone when empty)
# and <new launcher> is renamed over ~/.local/bin/herdr-agent. Either rename failing is
# undone. Only then do the copies aside become .previous. Returns 1 refused (signals may
# still be ignored; the caller restores them), 2 interrupted in a plain install. Sets
# HA_KEPT: pair (.previous is what was just replaced) | older (the older .previous pair
# stands) | none (no rollback target: a launcher that lost its tree link is removed
# rather than pair with another tree)
ha_exchange() {
  local g="$1" new_bin="$2" new_tree="$3" refusal="$4" kept=pair
  if [ -e "$HA_BIN" ] || [ -L "$HA_BIN" ]; then
    HA_PREP_BIN="$BIN_DIR/.herdr-agent.prev.$$"
    /bin/cp -P "$HA_BIN" "$HA_PREP_BIN" ||
      { ha_fail "$g" "couldn't copy the current herdr-agent aside; herdr-agent unchanged"; return 1; }
  fi
  # the new share link, made under the prevlink's name: step 1 exchanges it with the
  # current link, which leaves the outgoing link under that name
  if [ -n "$new_tree" ]; then
    HA_PREP_LINK="$SHARE_DIR/.herdr-agent.prevlink.$$"
    ln -s "$new_tree" "$HA_PREP_LINK" ||
      { ha_fail "$g" "couldn't prepare the new share link; herdr-agent unchanged"; return 1; }
  fi
  ha_pause prepared
  ha_abandoned && return 2

  # swap: two renames with signals ignored, so an interrupt here is dropped, not deferred
  trap '' INT TERM HUP
  local swapped=0
  if [ -n "$new_tree" ]; then
    if [ -L "$HA_SHARE" ]; then
      ha_swap_links "$HA_PREP_LINK" "$HA_SHARE" ||
        { ha_fail "$g" "couldn't replace ~/.local/share/herdr-agent; herdr-agent unchanged"; return 1; }
      swapped=1
    else
      # no link to exchange with (a first install), so nothing can be missing
      /bin/mv -fh "$HA_PREP_LINK" "$HA_SHARE" ||
        { ha_fail "$g" "couldn't replace ~/.local/share/herdr-agent; herdr-agent unchanged"; return 1; }
      HA_PREP_LINK=""
    fi
  fi
  ha_pause renames
  if ! ha_mv rename2 -f "$new_bin" "$HA_BIN"; then
    # undo step 1: the share link goes back to where it was, or away if there was none
    if [ "$swapped" = 1 ]; then
      ha_swap_links "$HA_PREP_LINK" "$HA_SHARE"
    elif [ -n "$new_tree" ]; then
      rm -f "$HA_SHARE"
    fi
    ha_fail "$g" "$refusal"
    return 1
  fi
  # From here the new copy is in: a failure below warns, and is never undone. The stage
  # is live now, so cleanup must not remove it
  HA_STAGE_BIN=""
  HA_STAGE_TREE=""
  if [ -n "$HA_PREP_BIN" ]; then
    ha_mv rename3 -f "$HA_PREP_BIN" "$HA_PREV" || kept=older
  fi
  if [ "$kept" = pair ] && [ -n "$HA_PREP_LINK" ] &&
    ! ha_mv rename4 -fh "$HA_PREP_LINK" "$HA_SHARE_PREV"; then
    # step 3 already made the launcher .previous; beside the older tree link it's a mixed pair
    if [ -n "$HA_PREP_BIN" ]; then
      rm -f "$HA_PREV"
      kept=none
    else
      kept=older
    fi
  fi
  # a rollback's step 2 used up .previous, so no older pair is left to fall back on
  [ "$kept" = older ] && ! ha_have_previous && kept=none
  HA_KEPT="$kept"
  ha_cleanup
  return 0
}

# Removes herdr-agent@* trees other than the current and previous ones. Not safe
# against a second installer at the same moment (accepted: installs run by hand)
ha_prune() {
  local keep_cur keep_prev d name
  # by name: a link made by hand may hold an absolute path
  keep_cur="$(basename "$(readlink "$HA_SHARE" 2>/dev/null)" 2>/dev/null)"
  keep_prev="$(basename "$(readlink "$HA_SHARE_PREV" 2>/dev/null)" 2>/dev/null)"
  for d in "$SHARE_DIR"/herdr-agent@*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    name="$(basename "$d")"
    [ "$name" = "$keep_cur" ] || [ "$name" = "$keep_prev" ] || rm -rf "$d"
  done
}

# ha_cmux_restart: add cmux's restart entries through the installed launcher when
# they're missing. Sets HA_CMUX: ok | nojq | failed, and HA_CMUX_REASON
ha_cmux_restart() {
  HA_CMUX=ok
  HA_CMUX_REASON=""
  local state out
  state="$(ha_restart_state "$HA_BIN")"
  case "$state" in
    present) return 0 ;;
    nojq)
      HA_CMUX=nojq
      say "⚠ cmux restart entries not checked; jq not found"
      return 1
      ;;
  esac
  if out="$("$HA_BIN" cmux-restart 2>&1)"; then
    log_line "herdr-agent cmux-restart: $out"
    say "✓ cmux restart entries added; cmux asks to approve them"
    return 0
  fi
  HA_CMUX=failed
  # the launcher warns with the reason first, then dies with a generic line; show the reason
  HA_CMUX_REASON="$(printf '%s\n' "$out" | sed -n 's/^herdr-agent: //p' | head -1)"
  [ -n "$HA_CMUX_REASON" ] || HA_CMUX_REASON="$(printf '%s\n' "$out" | grep -v '^$' | tail -1)"
  local home_label='~'
  HA_CMUX_REASON="${HA_CMUX_REASON//"$HOME"/$home_label}"
  log_line "herdr-agent cmux-restart failed: $out"
  say "⚠ cmux restart entries not added; ${HA_CMUX_REASON:-herdr-agent cmux-restart failed}"
  return 1
}

# ha_same_launcher <a> <b>: byte-identical files, or links with the same target
ha_same_launcher() {
  if [ -L "$1" ] || [ -L "$2" ]; then
    [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
  else
    cmp -s "$1" "$2"
  fi
}

# --herdr-agent --rollback: exchange current and previous. Without a previous tree
# (right after the first copy-install) only the launchers are exchanged
rollback_herdr_agent() {
  if ! ha_have_previous; then
    say "✗ no previous herdr-agent at ~/.local/bin/herdr-agent.previous; nothing changed"
    finish 1
  fi
  local tree=""
  [ -L "$HA_SHARE_PREV" ] && tree="$(readlink "$HA_SHARE_PREV")"
  if ha_same_launcher "$HA_PREV" "$HA_BIN"; then
    if { [ -z "$tree" ] && [ ! -L "$HA_SHARE" ]; } ||
      { [ -n "$tree" ] && [ "$tree" = "$(readlink "$HA_SHARE" 2>/dev/null)" ]; }; then
      say "✗ ~/.local/bin/herdr-agent.previous is the same as herdr-agent; nothing to roll back"
      finish 1
    fi
  fi

  # no previous tree: only the launchers are exchanged, and the share link stays
  ha_exchange ✗ "$HA_PREV" "$tree" "couldn't restore ~/.local/bin/herdr-agent; herdr-agent unchanged" ||
    finish 1
  trap 'finish 3' INT TERM
  trap - HUP
  log_line "rolled back herdr-agent"
  say "✓ rolled back herdr-agent (from herdr-agent.previous)"
  say ""
  # a rollback has no older pair to keep, so a failed step 3 or 4 always removes the target
  if [ "$HA_KEPT" = none ]; then
    say "⚠ couldn't keep the replaced herdr-agent; rollback target removed"
    say "  --herdr-agent --rollback has nothing to restore until the next install"
    log_line "herdr-agent.previous removed: the replaced copy couldn't be kept"
    say ""
    say "⚠ rolled back herdr-agent; rollback target removed"
    finish 3
  fi
  say "✓ rolled back herdr-agent; running agents keep the copy they started with"
  say "rollback     rbf/scripts/install-rbf.sh --herdr-agent --rollback"
  finish 0
}

# ---------------------------------------------------------------------------

print_plan() {
  local mode="$1" plan_bin sessions names hosting_name
  say "herdr-rbf install plan"
  say "  rbf version    $(rbf_version)"
  say "  revision       $(revision)"
  if [ "$mode" = rollback ]; then
    say "  install from   $PREVIOUS"
  elif [ -n "${RBF_INSTALL_PREBUILT:-}" ]; then
    say "  install from   $RBF_INSTALL_PREBUILT"
  else
    say "  install from   ${RBF_INSTALL_CARGO:-cargo} build --release --locked"
  fi
  say "  install to     $TARGET"
  if [ -e "$TARGET" ]; then
    say "  previous       kept as $PREVIOUS"
  else
    say "  previous       none (first install)"
  fi
  [ "$mode" = install ] && ha_plan_install

  if [ "$mode" != rollback ] && [ -x "$REPO/target/release/herdr" ]; then
    plan_bin="$REPO/target/release/herdr"
  elif [ -x "$TARGET" ]; then
    plan_bin="$TARGET"
  else
    plan_bin=""
  fi

  PLAN_SESSIONS=unknown
  if [ -z "$plan_bin" ]; then
    say "  sessions       unknown until built"
  elif sessions="$(list_sessions "$plan_bin")"; then
    if [ -z "$sessions" ]; then
      PLAN_SESSIONS=0
      say "  sessions       none running"
    else
      PLAN_SESSIONS=1
      names="$(printf '%s\n' "$sessions" | cut -f1 | paste -sd, - | sed 's/,/, /g')"
      hosting_name="$(printf '%s\n' "$sessions" | awk -F'\t' -v h="$HOSTING_SOCKET" '$2 == h { print $1 }')"
      if [ -n "$hosting_name" ]; then
        say "  sessions       $names (this window's session, last)"
      else
        say "  sessions       $names"
      fi
    fi
  else
    say "  sessions       unknown (session list failed)"
  fi
  say "  log            $LOG"

  local shadow
  shadow="$(path_shadow)"
  if [ -n "$shadow" ]; then
    say "⚠ another herdr comes first on PATH: $shadow"
    say "  remove it, or this install is not the herdr you run"
  fi
  if ! bin_dir_on_path; then
    say "⚠ ~/.local/bin is not on PATH; typing herdr won't find this install"
  fi
  if [ "$PLAN_SESSIONS" = 0 ]; then
    say "⚠ no running sessions; nothing to hand off"
  elif [ "$PLAN_SESSIONS" = 1 ]; then
    say "⚠ every attached herdr window closes when its session is handed off"
  fi
}

# The plan for --herdr-agent: herdr's rows give way to one line saying it's left alone
print_plan_herdr_agent() {
  local mode="$1"
  say "herdr-rbf install plan — herdr-agent only"
  say "  rbf version    $(rbf_version)"
  say "  revision       $(revision)"
  if [ "$mode" = rollback ]; then
    ha_plan_rollback
    say "  herdr          not touched; no session handed off"
  else
    ha_plan_install
    say "  herdr          not touched; no build, no session handed off"
  fi
  say "  log            $LOG"
  if ! bin_dir_on_path; then
    say "⚠ ~/.local/bin is not on PATH; typing herdr-agent won't find this install"
  fi
}

# swap_in <source>: one path for install and rollback. ~/.local/bin/herdr is never
# missing: the new file lands by one rename over the old one, and the outgoing
# binary, copied aside first, becomes herdr.previous right after.
swap_in() {
  local source="$1" version
  mkdir -p "$BIN_DIR" || { say "✗ can't create ~/.local/bin; nothing changed"; return 1; }
  STAGED="$BIN_DIR/.herdr.staged.$$"
  if ! /bin/cp -f "$source" "$STAGED" || ! chmod +x "$STAGED"; then
    cleanup_staged
    say "✗ couldn't stage $source; nothing changed in ~/.local/bin"
    return 1
  fi
  version="$("$STAGED" --version 2>/dev/null)"
  case "$version" in
    herdr\ *) ;;
    *)
      cleanup_staged
      say "✗ staged build doesn't run; nothing changed in ~/.local/bin"
      return 1
      ;;
  esac
  INSTALLED_VERSION="$version"

  if [ -e "$TARGET" ] && cmp -s "$STAGED" "$TARGET"; then
    # Same build: keep the older herdr.previous
    cleanup_staged
    STAGED=""
    return 0
  fi

  PREVIOUS_COPY=""
  if [ -e "$TARGET" ]; then
    PREVIOUS_COPY="$BIN_DIR/.herdr.previous.$$"
    if ! /bin/cp -fp "$TARGET" "$PREVIOUS_COPY"; then
      rm -f "$PREVIOUS_COPY"
      cleanup_staged
      say "✗ couldn't copy the current binary aside; nothing changed in ~/.local/bin"
      return 1
    fi
  fi

  # Signals stay ignored until main installs its post-swap handler, so nothing
  # lands between the two renames or between them and that handler
  trap '' INT TERM HUP
  if ! /bin/mv -f "$STAGED" "$TARGET"; then
    cleanup_staged
    say "✗ couldn't replace ~/.local/bin/herdr; nothing changed"
    return 1
  fi
  STAGED=""
  if [ -n "$PREVIOUS_COPY" ]; then
    if ! /bin/mv -f "$PREVIOUS_COPY" "$PREVIOUS"; then
      say "⚠ couldn't keep the previous build as ~/.local/bin/herdr.previous; it stays at $PREVIOUS_COPY"
      say "  --rollback would restore the older herdr.previous, not this build"
    fi
    # Either way the copy is no longer temporary, so the EXIT trap must not delete it
    PREVIOUS_COPY=""
  fi
  return 0
}

# main_herdr_agent <mode>: --herdr-agent, with install, dry-run or rollback. No build,
# no herdr, no handoff
main_herdr_agent() {
  local mode="$1"
  local plan_mode="$mode"
  [ "$mode" = dry-run ] && plan_mode=install
  print_plan_herdr_agent "$plan_mode"

  if [ "$mode" = dry-run ]; then
    say ""
    say "dry run — nothing built, nothing written, no session touched."
    exit 0
  fi

  trap ha_interrupted_only INT TERM
  say ""
  log_line "herdr-agent $mode rbf=$(rbf_version) rev=$(revision_id)"
  [ "$mode" = rollback ] && rollback_herdr_agent

  swap_in_herdr_agent ✗ || finish 1
  trap ha_interrupted_installed INT TERM
  trap - HUP

  local status=0
  if [ "$HA_RESULT" = kept-old ]; then
    status=3
  fi
  # an interrupt before the restart-entry step skips it; one during the step lets it finish
  trap ha_record_interrupt INT TERM
  ha_cmux_restart || status=3
  trap ha_interrupted_installed INT TERM
  if [ "$HA_INTERRUPTED" = 1 ]; then
    say "⚠ interrupted; herdr-agent is installed and its restart-entry step finished"
    finish 3
  fi

  say ""
  if [ "$HA_RESULT" = same ]; then
    if [ "$status" = 0 ]; then
      say "✓ nothing to install; herdr-agent is already this copy"
    else
      say "⚠ nothing to install; herdr-agent is already this copy"
    fi
  elif [ "$HA_RESULT" = kept-old ]; then
    say "⚠ installed herdr-agent; $(ha_target_note)"
  elif [ "$status" = 0 ]; then
    say "✓ installed herdr-agent; running agents keep the copy they started with"
  else
    say "⚠ installed herdr-agent"
  fi
  ha_finish_row
  if [ "$HA_RESULT" = installed ]; then
    say "rollback     rbf/scripts/install-rbf.sh --herdr-agent --rollback"
  fi
  finish "$status"
}

# What became of herdr-agent's rollback target, for a summary line
ha_target_note() {
  if [ "${HA_KEPT:-}" = none ]; then
    printf 'rollback target removed'
  else
    printf 'rollback target not updated'
  fi
}

# The summary's finish row, when a herdr-agent step is left to finish
ha_finish_row() {
  case "${HA_RESULT:-}" in
    refused | interrupted)
      say "finish       rbf/scripts/install-rbf.sh --herdr-agent"
      return
      ;;
  esac
  case "${HA_CMUX:-ok}" in
    nojq) say "finish       brew install jq, then herdr-agent cmux-restart" ;;
    failed) say "finish       herdr-agent cmux-restart" ;;
  esac
}

main() {
  local mode=install herdr_agent_only=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run | --rollback)
        # One mode per run: `--dry-run --rollback` must never roll back
        if [ "$mode" != install ]; then
          say "use one of --dry-run or --rollback, not both"
          usage >&2
          exit 2
        fi
        mode="${1#--}"
        ;;
      --herdr-agent)
        herdr_agent_only=1
        ;;
      -h | --help)
        usage >&2
        exit 0
        ;;
      *)
        say "unknown option: $1"
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  trap cleanup_staged EXIT

  if [ "$herdr_agent_only" = 1 ]; then
    main_herdr_agent "$mode"
  fi

  local plan_mode="$mode"
  [ "$mode" = dry-run ] && plan_mode=install
  print_plan "$plan_mode"

  if [ "$mode" = dry-run ]; then
    say ""
    say "dry run — nothing built, nothing written, no session touched."
    exit 0
  fi

  trap 'interrupted 1' INT TERM
  say ""
  log_line "$mode rbf=$(rbf_version) rev=$(revision_id)"

  local source
  if [ "$mode" = rollback ]; then
    if [ ! -f "$PREVIOUS" ]; then
      say "✗ no previous build at ~/.local/bin/herdr.previous; nothing changed"
      finish 1
    fi
    if [ -f "$TARGET" ] && cmp -s "$PREVIOUS" "$TARGET"; then
      say "✗ ~/.local/bin/herdr.previous is the same build as herdr; nothing to roll back"
      finish 1
    fi
    source="$PREVIOUS"
  elif [ -n "${RBF_INSTALL_PREBUILT:-}" ]; then
    source="$RBF_INSTALL_PREBUILT"
  else
    say "⋯ building release"
    if ! (cd "$REPO" && "${RBF_INSTALL_CARGO:-cargo}" build --release --locked); then
      say "✗ build failed; nothing was written to ~/.local/bin"
      finish 1
    fi
    source="$REPO/target/release/herdr"
  fi

  say "⋯ staging on the boot volume"
  swap_in "$source" || finish 1
  trap - HUP
  if [ "$mode" = rollback ]; then
    say "✓ rolled back to $INSTALLED_VERSION (from herdr.previous)"
  else
    say "✓ installed $INSTALLED_VERSION (rbf $(rbf_version), $(revision_id))"
  fi
  log_line "installed $INSTALLED_VERSION"

  # herdr-agent goes in after herdr, so exit 1 still means nothing was written; a
  # failure here warns and the sessions are still handed off
  local ha_status=0
  HA_RESULT=""
  HA_CMUX=ok
  if [ "$mode" = install ]; then
    trap ha_record_interrupt INT TERM
    swap_in_herdr_agent ⚠ || ha_status=3
    trap ha_record_interrupt INT TERM
    trap - HUP
    [ "$HA_RESULT" = kept-old ] && ha_status=3
    # An interrupt after the swap skips the restart-entry step if it hasn't started; one
    # during that step lets it finish. Either way the sessions are still handed off
    case "$HA_RESULT" in
      installed | kept-old | same)
        if [ "$HA_INTERRUPTED" = 1 ]; then
          say "⚠ interrupted; herdr-agent is installed, cmux restart entries not checked"
          ha_status=3
        else
          ha_cmux_restart || ha_status=3
          if [ "$HA_INTERRUPTED" = 1 ]; then
            say "⚠ interrupted; herdr-agent is installed and its restart-entry step finished"
            ha_status=3
          fi
        fi
        ;;
    esac
  fi
  trap 'interrupted 3' INT TERM

  local sessions
  if ! sessions="$(list_sessions "$TARGET")"; then
    say "⚠ couldn't list sessions; nothing handed off"
    finish 3
  fi

  local total=0 handed=0 name socket rc out result reattach_lines=""
  while IFS="$(printf '\t')" read -r name socket <&3; do
    [ -n "$name" ] || continue
    total=$((total + 1))
    # Ping first, so a skipped hosting session never claims its window closes
    if ! ping_socket "$socket"; then
      say "⋯ handing off $name"
      say "$(printf '⚠ %-10s not answering before handoff; skipped' "$name")"
      log_line "session $name skipped"
      continue
    fi

    if [ -n "$HOSTING_SOCKET" ] && [ "$socket" = "$HOSTING_SOCKET" ]; then
      say "⋯ handing off $name; this window closes now"
      say "  reattach with: $(reattach_command "$name")"
    else
      say "⋯ handing off $name"
    fi

    out="$(herdr_call "$TARGET" --session "$name" server live-handoff --import-exe "$TARGET" 2>&1)"
    rc=$?
    result="$(classify_handoff "$rc" "$socket")"
    case "$result" in
      handed-off)
        handed=$((handed + 1))
        say "$(printf '✓ %-10s handed off; pane processes still running' "$name")"
        reattach_lines="$reattach_lines$(reattach_command "$name")
"
        ;;
      kept)
        say "$(printf '✗ %-10s handoff failed: %s' "$name" "$(handoff_error "$out")")"
        say "             still running on its previous server; panes are safe"
        say "             rerun the install to retry"
        ;;
      none)
        say "$(printf '✗ %-10s no server answering after handoff' "$name")"
        say "             start it again: $(reattach_command "$name")"
        reattach_lines="$reattach_lines$(reattach_command "$name")
"
        ;;
    esac
    log_line "session $name $result rc=$rc"
  done 3<<EOF
$sessions
EOF

  local verb=installed status=0 glyph=✓ what
  [ "$mode" = rollback ] && verb="rolled back"
  [ "$handed" -eq "$total" ] || { status=3; glyph=⚠; }
  [ "$ha_status" = 0 ] || { status=3; glyph=⚠; }

  # What landed, in the summary line: herdr alone on a rollback
  what="$verb"
  case "$HA_RESULT" in
    installed) what="installed herdr and herdr-agent" ;;
    kept-old) what="installed herdr and herdr-agent; $(ha_target_note)" ;;
    same) what="installed herdr; herdr-agent unchanged" ;;
    refused | interrupted) what="installed herdr, not herdr-agent" ;;
  esac

  say ""
  if [ "$total" -eq 0 ]; then
    say "⚠ no running sessions; nothing to hand off"
    say "$glyph $what; no sessions to hand off"
  else
    say "$glyph $what; $handed of $total sessions handed off"
  fi
  if [ -n "$reattach_lines" ]; then
    local first=1 line
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      if [ "$first" = 1 ]; then
        say "reattach     $line"
        first=0
      else
        say "             $line"
      fi
    done <<EOF
$reattach_lines
EOF
  fi
  ha_finish_row
  if [ "$HA_RESULT" = installed ]; then
    say "rollback     herdr        rbf/scripts/install-rbf.sh --rollback"
    say "             herdr-agent  rbf/scripts/install-rbf.sh --herdr-agent --rollback"
  else
    say "rollback     rbf/scripts/install-rbf.sh --rollback"
  fi
  finish "$status"
}

if [ "${RBF_INSTALL_SOURCE_ONLY:-}" = 1 ]; then
  # `exit` covers running, rather than sourcing, the script with the seam set
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

main "$@"
