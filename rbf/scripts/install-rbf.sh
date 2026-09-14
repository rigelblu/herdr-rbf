#!/bin/bash

# Build the checked-out herdr-rbf revision and install it as the daily `herdr`,
# handing every running session to the new build so pane processes keep running.
#
# The binary lands at ~/.local/bin/herdr by one same-volume rename, and the
# outgoing binary is kept as ~/.local/bin/herdr.previous for --rollback.
# The session hosting this terminal is handed off last, because handoff closes
# every attached window.
#
# bash 3.2 (macOS /bin/bash): no associative arrays, no mapfile; python3 parses JSON.
#
# Test seams:
#   RBF_INSTALL_PREBUILT=<path>  install that file instead of building
#   RBF_INSTALL_CARGO=<cmd>      build command (default: cargo; not CARGO, which cargo
#                                itself exports to child processes)
#   RBF_INSTALL_SOURCE_ONLY=1    define the functions and return without running

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

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/install-rbf.sh [--dry-run | --rollback]

Build the checked-out herdr-rbf revision, install it as ~/.local/bin/herdr, and
hand every running session to it. Pane processes keep running; every attached
herdr window closes and reattaches with `herdr session attach <name>`.

Options:
  --dry-run    Print the plan; build nothing, write nothing, touch no session.
  --rollback   Swap herdr.previous back in and hand off the same way.
  -h, --help   Show this help.

Exit codes:
  0  installed, and every running session handed off
  1  nothing installed (build failed, or no usable herdr.previous)
  2  usage error
  3  installed, but at least one session wasn't handed off

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

main() {
  local mode=install
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
  trap 'interrupted 3' INT TERM
  trap - HUP
  if [ "$mode" = rollback ]; then
    say "✓ rolled back to $INSTALLED_VERSION (from herdr.previous)"
  else
    say "✓ installed $INSTALLED_VERSION (rbf $(rbf_version), $(revision_id))"
  fi
  log_line "installed $INSTALLED_VERSION"

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

  local verb=installed status=0 glyph=✓
  [ "$mode" = rollback ] && verb="rolled back"
  [ "$handed" -eq "$total" ] || { status=3; glyph=⚠; }

  say ""
  if [ "$total" -eq 0 ]; then
    say "⚠ no running sessions; nothing to hand off"
    say "✓ $verb; no sessions to hand off"
  else
    say "$glyph $verb; $handed of $total sessions handed off"
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
  say "rollback     rbf/scripts/install-rbf.sh --rollback"
  finish "$status"
}

if [ "${RBF_INSTALL_SOURCE_ONLY:-}" = 1 ]; then
  # `exit` covers running, rather than sourcing, the script with the seam set
  # shellcheck disable=SC2317
  return 0 2>/dev/null || exit 0
fi

main "$@"
