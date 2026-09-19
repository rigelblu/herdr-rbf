#!/bin/bash

# Isolated harness for rbf/scripts/install-rbf.sh (hrdr-5 Scenarios 2–10, 12, 13, 15–18;
# hrdr-9 Scenarios 4–16, 20, 21, 23–25 for herdr-agent).
#
#   rbf/scripts/install-rbf.test.sh <case>
#   cases: dry-run install hosting failed-handoff interrupted-handoff classify rollback refusals first-install
#          path-shadow alt-screen attached-window wedged real-agent busy-shell
#          herdr-agent-install herdr-agent-only herdr-agent-rollback herdr-agent-no-previous herdr-agent-no-gap
#          herdr-agent-refuse herdr-agent-same-build herdr-agent-after-build herdr-agent-interrupted
#          herdr-agent-first-install herdr-agent-no-relink herdr-agent-offline herdr-agent-first-rollback
#          herdr-agent-exit-3 herdr-agent-interrupted-plain herdr-agent-undo herdr-agent-previous-fails
#
# herdr-agent-after-build, herdr-agent-exit-3 and herdr-agent-interrupted-plain start real
# sessions, so they need target/release/herdr built; the other herdr-agent cases don't.
#
# Each case gets its own HOME and XDG dirs under <root>/<case>, or <root>/ha-* for the
# herdr-agent-* cases (short, so socket paths stay under macOS's 104 bytes), starts
# headless sessions from an "old" exec wrapper around the build under test, and refuses
# any socket outside that base. Your real sessions and ~/.local are never touched.
#
# <root> is $RBF_TEST_ROOT, else $EXTERNAL_DRIVE/tmp/rbf-h. A root on a volume under
# /Volumes must be mounted, so a case never writes onto the boot disk in its place.
# RBF_TEST_SKIP_BUILD=1 skips the up-front `cargo build --release --locked`.
# bash 3.2 compatible: per-session values live in files.

set -uo pipefail

CASE="${1:-}"
# The real home, saved before any case points HOME at its own base (real-agent needs
# claude's login)
REAL_HOME="$HOME"
ROOT="${RBF_TEST_ROOT:-${EXTERNAL_DRIVE:+$EXTERNAL_DRIVE/tmp/rbf-h}}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO/rbf/scripts/install-rbf.sh"
BUILD="$REPO/target/release/herdr"
# herdr-agent-* cases live under ha-*: a live handoff's socket path must stay under 104 bytes
case "$CASE" in herdr-agent-*) BASE="$ROOT/ha-${CASE#herdr-agent-}" ;; *) BASE="$ROOT/$CASE" ;; esac
BIN_DIR="$BASE/.local/bin"
TARGET="$BIN_DIR/herdr"
PREVIOUS="$BIN_DIR/herdr.previous"
OLD="$BASE/old-herdr"
CONFIG_DIR="$BASE/.config/herdr"
LOG="$BASE/Library/Logs/herdr-rbf-install.log"
SHARE_DIR="$BASE/.local/share"
HA_BIN="$BIN_DIR/herdr-agent"
HA_PREV="$BIN_DIR/herdr-agent.previous"
HA_SHARE="$SHARE_DIR/herdr-agent"
HA_SHARE_PREV="$SHARE_DIR/herdr-agent.previous"
HA_SRC_REPO="$REPO/rbf/src/herdr-agent"
PYTHON_DIR="$(dirname "$(command -v python3)")"
JJ_DIR="$(dirname "$(command -v jj 2>/dev/null || printf '/usr/bin/jj')")"
TEST_PATH="$BIN_DIR:$PYTHON_DIR:$JJ_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
FAILS=0

# ---------------------------------------------------------------------------
# Shared setup
# ---------------------------------------------------------------------------

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILS=$((FAILS + 1))
}
note() { printf 'NOTE  %s\n' "$*"; }
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

setv() { printf '%s' "$3" > "$BASE/vars/$1-$2"; }
getv() { cat "$BASE/vars/$1-$2" 2>/dev/null; }

isolated_env() {
  env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_SESSION -u HERDR_ENV \
    -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID -u ZDOTDIR \
    HOME="$BASE" XDG_CONFIG_HOME="$BASE/.config" XDG_STATE_HOME="$BASE/state" \
    XDG_RUNTIME_DIR="$BASE/run" PATH="$TEST_PATH" SHELL=/bin/zsh "$@"
}

# isolated_exec: isolated_env that replaces the calling (sub)shell, so a background
# job's $! is the command itself
isolated_exec() {
  exec env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_SESSION -u HERDR_ENV \
    -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID -u ZDOTDIR \
    HOME="$BASE" XDG_CONFIG_HOME="$BASE/.config" XDG_STATE_HOME="$BASE/state" \
    XDG_RUNTIME_DIR="$BASE/run" PATH="$TEST_PATH" SHELL=/bin/zsh "$@"
}

h() {
  local session="$1"
  shift
  isolated_env "$BUILD" --session "$session" "$@"
}

sock() {
  if [ "$1" = default ]; then
    printf '%s/herdr.sock' "$CONFIG_DIR"
  else
    printf '%s/sessions/%s/herdr.sock' "$CONFIG_DIR" "$1"
  fi
}

assert_base_socket() {
  case "$1" in
    "$BASE"/*) ;;
    *)
      echo "REFUSING socket outside the harness base: $1" >&2
      exit 1
      ;;
  esac
}

json_request() {
  python3 - "$1" "$2" <<'PY'
import socket, sys
c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
c.settimeout(10)
c.connect(sys.argv[1])
c.sendall(sys.argv[2].encode() + b"\n")
r = b""
while not r.endswith(b"\n"):
    ch = c.recv(65536)
    if not ch:
        break
    r += ch
print(r.decode().strip())
PY
}

answers() {
  json_request "$1" '{"id":"rbf-h:ping","method":"ping","params":{}}' 2>/dev/null | grep -q '"rbf-h:ping"'
}

wait_answers() {
  for _ in $(seq 1 200); do
    answers "$1" && return 0
    sleep 0.1
  done
  return 1
}

alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

new_pane() {
  json_request "$(sock "$1")" '{"id":"rbf-h:ws","method":"workspace.create","params":{"cwd":"/tmp","focus":true}}' |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["root_pane"]["pane_id"])'
}

send_line() {
  local body
  body="$(python3 -c 'import json,sys; print(json.dumps({"id":"rbf-h:send","method":"pane.send_input","params":{"pane_id":sys.argv[1],"text":sys.argv[2],"keys":["Enter"]}}))' "$2" "$3")"
  json_request "$(sock "$1")" "$body" > /dev/null
}

pane_read() {
  isolated_env "$TARGET" --session "$1" pane read "$2" --source "$3"
}

ticks() { wc -l < "$BASE/work/tick-$1" 2>/dev/null | tr -d ' '; }

# attach_window <session> <capture> [seconds]: attach a real herdr window in a pty the way
# Tom reattaches, since the server's post-handoff redraw nudge fires only on first attach
attach_window() {
  local bin="$TARGET"
  [ -x "$bin" ] || bin="$OLD"
  (sleep "${3:-60}" | isolated_env TERM=xterm-256color script -q "$2" sh -c "stty rows 40 cols 120; exec '$bin' --session $1" > /dev/null 2>&1) &
  sleep 3
  pgrep -f -- "script -q $2" | head -1
}

setup() {
  case "$ROOT" in
    /?*) ;;
    *)
      echo "no scratch root: set RBF_TEST_ROOT, or EXTERNAL_DRIVE (root \$EXTERNAL_DRIVE/tmp/rbf-h)" >&2
      exit 1
      ;;
  esac
  case "$BASE" in "$ROOT"/?*) ;; *) echo "bad base: $BASE" >&2; exit 1 ;; esac
  # A root on an unmounted volume would land on the boot disk under /Volumes instead
  local volume
  case "$ROOT" in
    /Volumes/?*)
      volume="/Volumes/$(printf '%s' "${ROOT#/Volumes/}" | cut -d/ -f1)"
      if ! mount | grep -Fq " on $volume ("; then
        echo "$volume not mounted" >&2
        exit 1
      fi
      ;;
  esac
  if [ "${RBF_TEST_SKIP_BUILD:-}" != 1 ]; then
    (cd "$REPO" && cargo build --release --locked) || { echo "build failed" >&2; exit 1; }
  fi
  rm -rf "$BASE"
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$BASE/state" "$BASE/run" "$BASE/vars" "$BASE/work"
  printf 'onboarding = false\n\n[update]\nversion_check = false\n' > "$CONFIG_DIR/config.toml"
  : > "$BASE/.zshrc"
  # cmux's restart entries as herdr-agent writes them, so the install's restart-entry
  # step finds them present and never reads a cmux app in /Applications
  mkdir -p "$BASE/.config/cmux"
  # shellcheck disable=SC2016  # evaluated by zsh
  HOME="$BASE" /bin/zsh -f -c '0=$1; eval "$(sed "/^case \\\$invoked in/,\$d" "$1")"; restart_entries' \
    ha "$HA_SRC_REPO/bin/herdr-agent" | jq -s '{definitions: .}' > "$BASE/.config/cmux/restart-commands.json"
  # Same behavior as the build, different bytes
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$BUILD" > "$OLD"
  chmod +x "$OLD"
  trap cleanup EXIT
  # A timeout or Ctrl+C would otherwise skip the EXIT trap and leave servers running
  trap 'exit 143' TERM
  trap 'exit 130' INT
}

install_old() { /bin/cp -f "$OLD" "$TARGET"; }

start_session() {
  local name="$1" s pane loop
  s="$(sock "$name")"
  assert_base_socket "$s"
  isolated_env "$OLD" --session "$name" server > "$BASE/server-$name.out" 2>&1 &
  setv server "$name" "$!"
  if ! wait_answers "$s"; then
    fail "$name: server never answered"
    exit 1
  fi
  pane="$(new_pane "$name")"
  setv pane "$name" "$pane"
  send_line "$name" "$pane" "sh -c 'echo \$\$ > $BASE/work/pid-$name; while :; do date +%s >> $BASE/work/tick-$name; sleep 1; done'"
  for _ in $(seq 1 100); do
    [ -s "$BASE/work/pid-$name" ] && break
    sleep 0.1
  done
  loop="$(cat "$BASE/work/pid-$name" 2>/dev/null)"
  setv loop "$name" "$loop"
  [ -n "$loop" ] || { fail "$name: pane loop never started"; exit 1; }
}

start_sessions() {
  local name
  for name in "$@"; do start_session "$name"; done
}

# run_install <out-file> [env assignments...] -- [args...]
run_install() {
  local out="$1"
  shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && shift
  isolated_env RBF_INSTALL_PREBUILT="$BUILD" ${envs[@]+"${envs[@]}"} "$INSTALL" "$@" > "$out.stdout" 2> "$out"
}

loops_alive() {
  local name
  for name in "$@"; do alive "$(getv loop "$name")" || return 1; done
}

loops_ticking() {
  local name before
  for name in "$@"; do setv ticks "$name" "$(ticks "$name")"; done
  sleep 3
  for name in "$@"; do
    before="$(getv ticks "$name")"
    [ "$(ticks "$name")" -gt "$before" ] || return 1
  done
}

has() { grep -Fq -- "$2" "$1"; }
has_not() { ! grep -Fq -- "$2" "$1"; }
same() { cmp -s "$1" "$2"; }

bin_snapshot() {
  (cd "$BIN_DIR" && for f in .[!.]* *; do [ -e "$f" ] && printf '%s %s\n' "$f" "$(cksum < "$f")"; done) 2>/dev/null
}

cleanup() {
  local name pid
  set +e
  for name in default work wedged; do
    [ -S "$(sock "$name")" ] && h "$name" server stop > /dev/null 2>&1
  done
  sleep 1
  # Only the harness's own processes: import servers and windows run from $BIN_DIR,
  # tick loops, attached windows, less, and the wedged listener carry these paths
  local pattern
  for pattern in "$BIN_DIR/herdr" "$BASE/work/pid-" "script -q $BASE/work/" "less $BASE/work/" "$CONFIG_DIR/sessions/wedged/herdr.sock"; do
    for pid in $(pgrep -f -- "$pattern"); do
      [ "$pid" = $$ ] || kill -9 "$pid" 2> /dev/null
    done
  done
  for name in default work wedged; do
    for pid in "$(getv loop "$name")" "$(getv server "$name")" "$(getv listener "$name")"; do
      alive "$pid" && kill -9 "$pid" 2> /dev/null
    done
  done
}

# ---------------------------------------------------------------------------
# Cases
# ---------------------------------------------------------------------------

# shellcheck disable=SC2016  # conditions are evaluated by check
case_dry_run() {
  install_old
  start_sessions default work
  local before out="$BASE/dry-run.err" rc home_before
  before="$(bin_snapshot)"
  home_before="$(home_snapshot)"
  run_install "$out" -- --dry-run
  rc=$?
  check "exit 0" [ "$rc" -eq 0 ]
  check "plan: rbf version" has "$out" "  rbf version    "
  check "plan: revision" has "$out" "  revision       "
  check "plan: install to" has "$out" "  install to     $TARGET"
  check "plan: sessions default, work" has "$out" "  sessions       default, work"
  check "dry run line" has "$out" "dry run — nothing built, nothing written, no session touched."
  check "bin dir unchanged" [ "$before" = "$(bin_snapshot)" ]
  check "servers unchanged" alive "$(getv server default)"
  check "work server unchanged" alive "$(getv server work)"
  check "nothing on stdout" [ ! -s "$out.stdout" ]
  check "no PATH warning when ~/.local/bin is on PATH" has_not "$out" "is not on PATH"

  out="$BASE/dry-run-no-path.err"
  isolated_env PATH="$PYTHON_DIR:$JJ_DIR:/usr/bin:/bin:/usr/sbin:/sbin" RBF_INSTALL_PREBUILT="$BUILD" "$INSTALL" --dry-run > "$out.stdout" 2> "$out"
  check "PATH warning when ~/.local/bin is missing from PATH" has "$out" "⚠ ~/.local/bin is not on PATH; typing herdr won't find this install"

  # hrdr-9 Scenario 16: herdr-agent in both plans, and nothing written under HOME
  out="$BASE/dry-run.err"
  check "plan: herdr-agent source" has "$out" "  herdr-agent    from      rbf/src/herdr-agent"
  check "plan: herdr-agent launcher" has "$out" "                 to        $HA_BIN"
  check "plan: herdr-agent tree" has "$out" "                           $HA_SHARE"
  check "plan: herdr-agent previous" has "$out" "                 previous  none (first install)"
  check "plan: cmux restart entries" has "$out" "                 cmux      restart entries present"
  check "plan: herdr-agent rows between herdr's previous and sessions" eval \
    '[ "$(grep -n "  herdr-agent    from" "$out" | cut -d: -f1)" -gt "$(grep -n "  previous       " "$out" | cut -d: -f1)" ] &&
     [ "$(grep -n "  herdr-agent    from" "$out" | cut -d: -f1)" -lt "$(grep -n "  sessions       " "$out" | cut -d: -f1)" ]'
  check "plan: never the timestamped tree" has_not "$out" "herdr-agent@"
  out="$BASE/dry-run-herdr-agent.err"
  run_install "$out" -- --herdr-agent --dry-run
  rc=$?
  check "--herdr-agent --dry-run: exit 0" [ "$rc" -eq 0 ]
  check "--herdr-agent --dry-run: heading" has "$out" "herdr-rbf install plan — herdr-agent only"
  check "--herdr-agent --dry-run: source" has "$out" "  herdr-agent    from      rbf/src/herdr-agent"
  check "--herdr-agent --dry-run: launcher" has "$out" "                 to        $HA_BIN"
  check "--herdr-agent --dry-run: tree" has "$out" "                           $HA_SHARE"
  check "--herdr-agent --dry-run: previous" has "$out" "                 previous  none (first install)"
  check "--herdr-agent --dry-run: herdr not touched" has "$out" "  herdr          not touched; no build, no session handed off"
  check "--herdr-agent --dry-run: no herdr rows" has_not "$out" "  install to     "
  check "--herdr-agent --dry-run: dry run line" has "$out" "dry run — nothing built, nothing written, no session touched."
  check "nothing under HOME's .local or cmux config changed" [ "$home_before" = "$(home_snapshot)" ]
}

home_snapshot() {
  (cd "$BASE" && find .local .config/cmux Library -print 2> /dev/null | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; else printf '%s\n' "$f"; fi
  done)
}

case_install() {
  install_old
  start_sessions default work
  local out="$BASE/install-1.err" rc
  run_install "$out"
  rc=$?
  check "first install exit 0" [ "$rc" -eq 0 ]
  check "default handed off" has "$out" "✓ default    handed off; pane processes still running"
  check "work handed off" has "$out" "✓ work       handed off; pane processes still running"
  check "verdict line" has "$out" "✓ installed herdr and herdr-agent; 2 of 2 sessions handed off"
  check "loops alive" loops_alive default work
  check "loops still ticking 3s later" loops_ticking default work
  check "herdr is the build" same "$TARGET" "$BUILD"
  check "herdr.previous is the old wrapper" same "$PREVIOUS" "$OLD"
  check "log: one install line" [ "$(grep -c ' install rbf=' "$LOG")" -eq 1 ]
  check "log: two session lines" [ "$(grep -c ' session ' "$LOG")" -eq 2 ]

  out="$BASE/install-2.err"
  run_install "$out"
  rc=$?
  check "rerun exit 0" [ "$rc" -eq 0 ]
  check "rerun default handed off" has "$out" "✓ default    handed off"
  check "rerun work handed off" has "$out" "✓ work       handed off"
  check "rerun loops alive" loops_alive default work
  check "rerun keeps the old wrapper as herdr.previous" same "$PREVIOUS" "$OLD"
}

case_hosting() {
  install_old
  start_sessions default work
  local pane rc
  pane="$(new_pane work)"
  # Sent into work's own pane, so HERDR_SOCKET_PATH there names work as the hosting session
  send_line work "$pane" "cd '$REPO' && env HOME='$BASE' XDG_CONFIG_HOME='$BASE/.config' XDG_STATE_HOME='$BASE/state' XDG_RUNTIME_DIR='$BASE/run' PATH='$TEST_PATH' RBF_INSTALL_PREBUILT='$BUILD' rbf/scripts/install-rbf.sh"
  for _ in $(seq 1 600); do
    grep -q ' exit [0-9]' "$LOG" 2> /dev/null && break
    sleep 0.1
  done
  rc="$(sed -n 's/.* exit \([0-9]*\)$/\1/p' "$LOG" 2> /dev/null | tail -1)"
  check "install exit 0 (from the log)" [ "${rc:-x}" = 0 ]
  local d w
  d="$(grep -n ' session default ' "$LOG" | cut -d: -f1)"
  w="$(grep -n ' session work ' "$LOG" | cut -d: -f1)"
  check "work (hosting) handed off after default" [ "${w:-0}" -gt "${d:-999999}" ]
  sleep 1
  pane_read work "$pane" recent > "$BASE/hosting-pane.txt" 2>&1
  check "hosting pane shows reattach" has "$BASE/hosting-pane.txt" "reattach"
  check "hosting pane shows the closes-now line" has "$BASE/hosting-pane.txt" "⋯ handing off work; this window closes now"
  check "loops alive" loops_alive default work
}

case_failed_handoff() {
  install_old
  start_sessions default work
  local wrapper="$BASE/failing-import" out="$BASE/failed.err" rc started
  # shellcheck disable=SC2016  # $2 and $@ belong to the wrapper, not this shell
  printf '#!/bin/sh\n[ "$2" = --handoff-import ] && exit 1\nexec "%s" "$@"\n' "$BUILD" > "$wrapper"
  chmod +x "$wrapper"
  started=$(date +%s)
  run_install "$out" RBF_INSTALL_PREBUILT="$wrapper" --
  rc=$?
  note "took $(($(date +%s) - started))s"
  check "exit 3" [ "$rc" -eq 3 ]
  check "default: handoff failed" has "$out" "✗ default    handoff failed:"
  check "work: handoff failed" has "$out" "✗ work       handoff failed:"
  check "still running on its previous server" [ "$(grep -c 'still running on its previous server; panes are safe' "$out")" -eq 2 ]
  check "loops alive" loops_alive default work
  check "default answers" answers "$(sock default)"
  check "work answers" answers "$(sock work)"
}

# classify_isolated <rc> <socket>: load the script in a subshell with the harness HOME, so its
# top-level BIN_DIR/TARGET/LOG never rebind this shell's variables to the real home
classify_isolated() {
  (
    export HOME="$BASE"
    export RBF_INSTALL_SOURCE_ONLY=1
    # shellcheck disable=SC1090,SC1091  # the script under test; linted on its own
    . "$INSTALL"
    classify_handoff "$1" "$2"
  )
}

case_classify() {
  start_sessions default
  local got
  got="$(classify_isolated 1 "$BASE/missing.sock")"
  check "rc 1, missing socket → none (got $got)" [ "$got" = none ]
  got="$(classify_isolated 0 "$BASE/missing.sock")"
  check "rc 0, missing socket → none (got $got)" [ "$got" = none ]
  got="$(classify_isolated 1 "$(sock default)")"
  check "rc 1, answering socket → kept (got $got)" [ "$got" = kept ]
  got="$(classify_isolated 0 "$(sock default)")"
  check "rc 0, answering socket → handed-off (got $got)" [ "$got" = handed-off ]
  check "harness TARGET still under the base" [ "$TARGET" = "$BASE/.local/bin/herdr" ]
}

case_rollback() {
  install_old
  start_sessions default work
  run_install "$BASE/install.err"
  check "setup install exit 0" [ $? -eq 0 ]
  # herdr-agent A over the one the install put in, so a rollback that reached herdr-agent
  # would change it (hrdr-9: --rollback never touches herdr-agent)
  local a ha_before
  a="$(ha_source A)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "setup: herdr-agent A installed" installed_is "$a"
  ha_before="$(ha_state)"

  local watcher out="$BASE/rollback-1.err" rc
  (while :; do [ -x "$TARGET" ] || echo MISSING >> "$BASE/work/missing"; sleep 0.01; done) &
  watcher=$!
  run_install "$out" -- --rollback
  rc=$?
  kill "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  check "rollback exit 0" [ "$rc" -eq 0 ]
  check "herdr is the old wrapper" same "$TARGET" "$OLD"
  check "herdr.previous is the build" same "$PREVIOUS" "$BUILD"
  check "default handed off" has "$out" "✓ default    handed off"
  check "work handed off" has "$out" "✓ work       handed off"
  check "loops alive" loops_alive default work
  check "herdr never missing during rollback" [ ! -e "$BASE/work/missing" ]
  check "rollback left herdr-agent byte-identical" [ "$ha_before" = "$(ha_state)" ]
  check "rollback output never mentions herdr-agent" has_not "$out" "herdr-agent"

  out="$BASE/rollback-2.err"
  run_install "$out" -- --rollback
  rc=$?
  check "second rollback exit 0" [ "$rc" -eq 0 ]
  check "herdr is the build again" same "$TARGET" "$BUILD"
  check "herdr.previous is the old wrapper again" same "$PREVIOUS" "$OLD"
  check "loops alive after second rollback" loops_alive default work
  check "second rollback left herdr-agent byte-identical" [ "$ha_before" = "$(ha_state)" ]
  check "second rollback output never mentions herdr-agent" has_not "$out" "herdr-agent"
}

case_refusals() {
  install_old
  local before out rc

  before="$(bin_snapshot)"
  out="$BASE/no-previous.err"
  run_install "$out" -- --rollback
  rc=$?
  check "no previous: exit 1" [ "$rc" -eq 1 ]
  check "no previous: message" has "$out" "✗ no previous build at ~/.local/bin/herdr.previous; nothing changed"
  check "no previous: bin unchanged" [ "$before" = "$(bin_snapshot)" ]

  /bin/cp -f "$TARGET" "$PREVIOUS"
  before="$(bin_snapshot)"
  out="$BASE/identical.err"
  run_install "$out" -- --rollback
  rc=$?
  check "identical previous: exit 1" [ "$rc" -eq 1 ]
  check "identical previous: message" has "$out" "✗ ~/.local/bin/herdr.previous is the same build as herdr; nothing to roll back"
  check "identical previous: bin unchanged" [ "$before" = "$(bin_snapshot)" ]
  rm -f "$PREVIOUS"

  before="$(bin_snapshot)"
  out="$BASE/build-failed.err"
  isolated_env RBF_INSTALL_CARGO=/usr/bin/false "$INSTALL" > "$out.stdout" 2> "$out"
  rc=$?
  check "build failed: exit 1" [ "$rc" -eq 1 ]
  check "build failed: message" has "$out" "✗ build failed; nothing was written to ~/.local/bin"
  check "build failed: bin unchanged" [ "$before" = "$(bin_snapshot)" ]

  # Interrupted build: TERM (a background job ignores INT) keeps exit 1 and logs the exit line
  printf '#!/bin/sh\nsleep 3\n' > "$BASE/slow-cargo"
  chmod +x "$BASE/slow-cargo"
  before="$(bin_snapshot)"
  out="$BASE/interrupted.err"
  # exec, so $! is the install script itself rather than a subshell running a function
  (isolated_exec RBF_INSTALL_CARGO="$BASE/slow-cargo" "$INSTALL" > "$out.stdout" 2> "$out") &
  local install_pid=$!
  sleep 1
  kill -TERM "$install_pid"
  wait "$install_pid"
  rc=$?
  check "interrupted build: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "interrupted build: message" has "$out" "✗ interrupted; nothing was written to ~/.local/bin"
  check "interrupted build: log ends with exit 1 ($(tail -1 "$LOG"))" [ "$(tail -1 "$LOG" | sed 's/.* exit //')" = 1 ]
  check "interrupted build: bin unchanged" [ "$before" = "$(bin_snapshot)" ]

  for flags in "--dry-run --rollback" "--rollback --dry-run"; do
    /bin/cp -f "$OLD" "$PREVIOUS"
    printf 'different\n' >> "$PREVIOUS"
    before="$(bin_snapshot)"
    out="$BASE/two-modes.err"
    # shellcheck disable=SC2086  # the two flags are meant to split
    run_install "$out" -- $flags
    rc=$?
    check "$flags: exit 2" [ "$rc" -eq 2 ]
    check "$flags: message" has "$out" "use one of --dry-run or --rollback, not both"
    check "$flags: bin unchanged" [ "$before" = "$(bin_snapshot)" ]
    rm -f "$PREVIOUS"
  done

  before="$(bin_snapshot)"
  out="$BASE/bogus.err"
  run_install "$out" -- --bogus
  rc=$?
  check "unknown option: exit 2" [ "$rc" -eq 2 ]
  check "unknown option: usage" has "$out" "Usage: rbf/scripts/install-rbf.sh"
  check "unknown option: bin unchanged" [ "$before" = "$(bin_snapshot)" ]

  # A staged build that doesn't answer --version is refused before any rename
  printf '#!/bin/sh\nexit 0\n' > "$BASE/silent-build"
  chmod +x "$BASE/silent-build"
  before="$(bin_snapshot)"
  out="$BASE/silent-build.err"
  run_install "$out" RBF_INSTALL_PREBUILT="$BASE/silent-build" --
  rc=$?
  check "staged build doesn't run: exit 1" [ "$rc" -eq 1 ]
  check "staged build doesn't run: message" has "$out" "✗ staged build doesn't run; nothing changed in ~/.local/bin"
  check "staged build doesn't run: bin unchanged" [ "$before" = "$(bin_snapshot)" ]

  # session list failing after the swap: installed, nothing handed off, exit 3, no verdict line
  # shellcheck disable=SC2016  # $1 and $@ belong to the wrapper, not this shell
  printf '#!/bin/sh\n[ "$1" = session ] && exit 1\nexec "%s" "$@"\n' "$BUILD" > "$BASE/no-session-list"
  chmod +x "$BASE/no-session-list"
  out="$BASE/no-session-list.err"
  run_install "$out" RBF_INSTALL_PREBUILT="$BASE/no-session-list" --
  rc=$?
  check "session list fails: exit 3" [ "$rc" -eq 3 ]
  check "session list fails: message" has "$out" "⚠ couldn't list sessions; nothing handed off"
  check "session list fails: herdr is the new build" same "$TARGET" "$BASE/no-session-list"
  check "session list fails: no verdict or rollback line" has_not "$out" "rollback     "
}

case_interrupted_handoff() {
  install_old
  start_sessions default work
  local wrapper="$BASE/failing-import" out="$BASE/interrupted-handoff.err" rc install_pid
  # A failing import holds each handoff ~30s, so TERM lands after the swap, mid-handoff
  # shellcheck disable=SC2016  # $2 and $@ belong to the wrapper, not this shell
  printf '#!/bin/sh\n[ "$2" = --handoff-import ] && exit 1\nexec "%s" "$@"\n' "$BUILD" > "$wrapper"
  chmod +x "$wrapper"
  (isolated_exec RBF_INSTALL_PREBUILT="$wrapper" "$INSTALL" > "$out.stdout" 2> "$out") &
  install_pid=$!
  for _ in $(seq 1 100); do
    grep -q '⋯ handing off default' "$out" 2> /dev/null && break
    sleep 0.1
  done
  # Without this the case could pass with TERM landing before any handoff started
  check "interrupted handoff: TERM sent mid-handoff" has "$out" "⋯ handing off default"
  kill -TERM "$install_pid"
  wait "$install_pid"
  rc=$?
  check "interrupted handoff: exit 3 (got $rc)" [ "$rc" -eq 3 ]
  check "interrupted handoff: message" has "$out" "⚠ interrupted during handoffs; rerun the install to hand off every session"
  check "interrupted handoff: log ends with exit 3 ($(tail -1 "$LOG"))" [ "$(tail -1 "$LOG" | sed 's/.* exit //')" = 3 ]
  # Both failing handoffs also end in exit 3, so prove the run stopped instead of finishing
  check "interrupted handoff: work never attempted" has_not "$LOG" " session work "
  check "interrupted handoff: herdr is the new build" same "$TARGET" "$wrapper"
  check "interrupted handoff: herdr.previous is the old wrapper" same "$PREVIOUS" "$OLD"
  check "interrupted handoff: no stray temp files" [ -z "$(find "$BIN_DIR" -maxdepth 1 -name '.herdr.*')" ]
  check "interrupted handoff: loops alive" loops_alive default work
  check "interrupted handoff: no verdict or rollback line" has_not "$out" "rollback     "
}

case_first_install() {
  local out="$BASE/first.err" rc
  run_install "$out"
  rc=$?
  check "exit 0" [ "$rc" -eq 0 ]
  check "plan: previous none" has "$out" "  previous       none (first install)"
  check "no running sessions warning" has "$out" "⚠ no running sessions; nothing to hand off"
  check "no herdr.previous written" [ ! -e "$PREVIOUS" ]
  check "herdr is the build" same "$TARGET" "$BUILD"
}

case_path_shadow() {
  install_old
  start_sessions default work
  mkdir -p "$BASE/shadow"
  printf '#!/bin/sh\necho called >> "%s"\n' "$BASE/work/shadow-called" > "$BASE/shadow/herdr"
  chmod +x "$BASE/shadow/herdr"
  local out="$BASE/shadow.err" rc
  isolated_env RBF_INSTALL_PREBUILT="$BUILD" PATH="$BASE/shadow:$TEST_PATH" "$INSTALL" > "$out.stdout" 2> "$out"
  rc=$?
  check "exit 0" [ "$rc" -eq 0 ]
  check "shadow warning" has "$out" "⚠ another herdr comes first on PATH: $BASE/shadow/herdr"
  check "default handed off" has "$out" "✓ default    handed off"
  check "work handed off" has "$out" "✓ work       handed off"
  check "shadow never run" [ ! -e "$BASE/work/shadow-called" ]
}

case_alt_screen() {
  install_old
  start_sessions default work
  local pane less_pid before after
  pane="$(new_pane work)"
  /bin/cp -f /etc/services "$BASE/work/lessfile"
  send_line work "$pane" "less $BASE/work/lessfile"
  sleep 2
  less_pid="$(pgrep -f -- "less $BASE/work/lessfile" | head -1)"
  isolated_env "$OLD" --session work pane read "$pane" --source visible > "$BASE/alt-before.txt" 2>&1
  run_install "$BASE/alt.err"
  check "install exit 0" [ $? -eq 0 ]
  sleep 2
  pane_read work "$pane" visible > "$BASE/alt-after.txt" 2>&1
  note "pane read after handoff: rc $?, $(grep -c '[^[:space:]]' "$BASE/alt-after.txt") non-blank lines"
  check "less pid kept ($less_pid)" alive "$less_pid"
  # Recorded, not gated: does the screen come back once a window reattaches?
  attach_window work "$BASE/work/alt-window" 20 > /dev/null
  pane_read work "$pane" visible > "$BASE/alt-after-attach.txt" 2>&1
  note "after a window reattaches: $(grep -c '[^[:space:]]' "$BASE/alt-after-attach.txt") non-blank lines"
  # The window attaches at 40x120, so less redraws at the new size: compare content, not bytes
  before="$(grep -c '[^[:space:]]' "$BASE/alt-before.txt")"
  after="$(grep -c '[^[:space:]]' "$BASE/alt-after-attach.txt")"
  check "less redrew its screen once a window reattached ($before lines before, $after after)" [ "$after" -gt 0 ]
  check "reattached screen still shows the file" has "$BASE/alt-after-attach.txt" "# Network services, Internet style"
}

case_attached_window() {
  install_old
  start_sessions default work
  local script_pid exited=""
  # script's pty starts 0x0, which herdr refuses, so size it before attaching
  (sleep 60 | isolated_env TERM=xterm-256color script -q "$BASE/work/capture" sh -c "stty rows 40 cols 120; exec '$OLD' --session work" > /dev/null 2>&1) &
  sleep 3
  script_pid="$(pgrep -f -- "script -q $BASE/work/capture" | head -1)"
  check "window attached ($script_pid)" alive "$script_pid"
  run_install "$BASE/attached.err"
  check "install exit 0" [ $? -eq 0 ]
  for _ in $(seq 1 50); do
    alive "$script_pid" || { exited=1; break; }
    sleep 0.1
  done
  check "window exited within 5s of handoff" [ -n "$exited" ]
  check "capture has the shutdown message" has "$BASE/work/capture" "server shut down: live update in progress"
}

case_wedged() {
  install_old
  start_sessions default work
  local wsock="$CONFIG_DIR/sessions/wedged/herdr.sock" out="$BASE/wedged.err" rc started elapsed
  mkdir -p "$(dirname "$wsock")"
  python3 - "$wsock" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(sys.argv[1])
s.listen(64)
held = []
while True:
    c, _ = s.accept()
    held.append(c)
PY
  setv listener wedged "$!"
  for _ in $(seq 1 50); do
    [ -S "$wsock" ] && break
    sleep 0.1
  done
  isolated_env "$BUILD" session list --json > "$BASE/wedged-list.json" 2>&1
  check "session list shows wedged running" has "$BASE/wedged-list.json" '"name":"wedged","running":true'
  started=$(date +%s)
  run_install "$out"
  rc=$?
  elapsed=$(($(date +%s) - started))
  check "exit 3" [ "$rc" -eq 3 ]
  check "wedged skipped" has "$out" "⚠ wedged     not answering before handoff; skipped"
  check "default handed off" has "$out" "✓ default    handed off"
  check "work handed off" has "$out" "✓ work       handed off"
  check "finished within 30s (${elapsed}s)" [ "$elapsed" -le 30 ]
}

case_real_agent() {
  install_old
  start_sessions default work
  local pane claude_pid out
  local claude_bin
  claude_bin="$(command -v claude)"
  [ -n "$claude_bin" ] || { fail "claude not found on this shell's PATH"; return; }
  pane="$(new_pane work)"
  send_line work "$pane" "HOME='$REAL_HOME' '$claude_bin' --model haiku 'reply with the word ready'"
  sleep 25
  claude_pid="$(pgrep -f -- "--model haiku reply with the word ready" | head -1)"
  isolated_env "$OLD" --session work agent get "$pane" > "$BASE/agent-before.txt" 2>&1
  note "agent get before: $(tr '\n' ' ' < "$BASE/agent-before.txt" | head -c 300)"
  pane_read_old() { isolated_env "$OLD" --session work pane read "$pane" --source visible; }
  pane_read_old > "$BASE/agent-screen-before.txt" 2>&1
  out="$BASE/agent.err"
  run_install "$out"
  check "work handed off" has "$out" "✓ work       handed off"
  check "claude pid kept ($claude_pid)" alive "$claude_pid"
  pane_read work "$pane" visible > "$BASE/agent-screen-after.txt" 2>&1
  note "visible lines right after handoff: $(grep -c '[^[:space:]]' "$BASE/agent-screen-after.txt")"
  attach_window work "$BASE/work/agent-window" 20 > /dev/null
  pane_read work "$pane" visible > "$BASE/agent-screen-after-attach.txt" 2>&1
  note "visible lines after a window reattaches: $(grep -c '[^[:space:]]' "$BASE/agent-screen-after-attach.txt")"
  send_line work "$pane" "/exit"
}

case_busy_shell() {
  install_old
  start_sessions default work
  local pane loop
  pane="$(new_pane work)"
  sleep 1
  # shellcheck disable=SC2016  # the loop runs in the pane's zsh
  loop='for i in 1 2 3 4 5 6 7 8; do echo line-$i; sleep 1; done; echo MARK-DONE; read -t 2 -k 1 k; [[ $k == $'"'"'\f'"'"' ]] && echo MARK-FF-YES || echo MARK-FF-NO'

  send_line work "$pane" "${loop//MARK/CONTROL}"
  sleep 13
  pane_read work "$pane" recent > "$BASE/busy-control.txt" 2>&1
  note "control: $(grep -o 'CONTROL-FF-[A-Z]*' "$BASE/busy-control.txt" | tail -1), done line on screen: $(grep -c '^CONTROL-DONE' "$BASE/busy-control.txt")"

  send_line work "$pane" "${loop//MARK/INSTALL}"
  sleep 2
  run_install "$BASE/busy.err"
  check "install exit 0" [ $? -eq 0 ]
  sleep 13
  pane_read work "$pane" recent > "$BASE/busy-install.txt" 2>&1
  note "install: $(grep -o 'INSTALL-FF-[A-Z]*' "$BASE/busy-install.txt" | tail -1), done line on screen: $(grep -c '^INSTALL-DONE' "$BASE/busy-install.txt")"

  # #hrdr-4 saw the form feed in a later command in a pane handed off earlier, with a window
  # attached; reattach first so the redraw nudge fires
  attach_window work "$BASE/work/busy-window" 40 > /dev/null
  send_line work "$pane" "${loop//MARK/AFTER}"
  sleep 13
  pane_read work "$pane" recent > "$BASE/busy-after.txt" 2>&1
  note "after handoff: $(grep -o 'AFTER-FF-[A-Z]*' "$BASE/busy-after.txt" | tail -1), done line on screen: $(grep -c '^AFTER-DONE' "$BASE/busy-after.txt")"
}


# ---------------------------------------------------------------------------
# herdr-agent (hrdr-9 Scenarios 4–16, 20, 21, 23–25)
# ---------------------------------------------------------------------------

# The installer's own seams put each case's herdr-agent source in its own copy, so
# "A" and "B" are two copies of rbf/src/herdr-agent with a variant marker written into
# both the launcher and the tree's hook-cmux; a broken copy has its defect written in.
# A consistent pair is checked, not assumed: the installed launcher's own `links`,
# evaluated with $0 set to its path, must name a tree whose hook-cmux carries the
# launcher's marker.

# ha_source <name>: a marked copy of the source, printed as its path
ha_source() {
  local dir="$BASE/src-$1"
  rm -rf "$dir"
  /bin/cp -pR "$HA_SRC_REPO" "$dir"
  printf '# variant %s\n' "$1" >> "$dir/bin/herdr-agent"
  printf '# variant %s\n' "$1" >> "$dir/share/herdr-agent/hook-cmux"
  printf '%s' "$dir"
}

# ha_run <out> <source> [env assignments...] -- [args...]
ha_run() {
  local out="$1" src="$2"
  shift 2
  run_install "$out" RBF_INSTALL_HERDR_AGENT_SRC="$src" "$@"
}

ha_marker() { sed -n 's/^# variant //p' "$1" 2> /dev/null | tail -1; }

# The launcher's marker and its tree's, as "launcher/tree"
ha_pair() {
  local links
  # shellcheck disable=SC2016  # evaluated by zsh, with $0 set to the launcher
  links="$(isolated_env /bin/zsh -f -c '0=$1; eval "$(sed "/^case \\\$invoked in/,\$d" "$1")"; print -r -- $links' \
    ha "$HA_BIN" 2> /dev/null)"
  printf '%s/%s' "$(ha_marker "$HA_BIN")" "$(ha_marker "$(dirname "$links")/hook-cmux")"
}

consistent_as() { [ "$(ha_pair)" = "$1/$1" ]; }

# Every herdr-agent path this installer owns, with contents: both launchers, both
# tree links and what's behind them, every tree, and any temporary file left behind
ha_state() {
  local p
  for p in "$HA_BIN" "$HA_PREV" "$HA_SHARE" "$HA_SHARE_PREV"; do
    if [ -L "$p" ]; then
      printf '%s link %s\n' "${p##*/}" "$(readlink "$p")"
    elif [ -f "$p" ]; then
      printf '%s file %s\n' "${p##*/}" "$(cksum < "$p")"
    elif [ -e "$p" ]; then
      printf '%s other\n' "${p##*/}"
    else
      printf '%s none\n' "${p##*/}"
    fi
  done
  for p in "$SHARE_DIR"/herdr-agent@*; do
    [ -d "$p" ] || continue
    printf 'tree %s\n' "${p##*/}"
    tree_shape "$p"
  done
  find "$BIN_DIR" "$SHARE_DIR" -maxdepth 1 -name '.herdr-agent.*' 2> /dev/null | sed 's/^/temp /'
}

# Every entry under a tree: path, and a link's target or a file's checksum
tree_shape() {
  (cd "$1" && find . -mindepth 1 -print | LC_ALL=C sort | while IFS= read -r f; do
    if [ -L "$f" ]; then
      printf '  %s -> %s\n' "$f" "$(readlink "$f")"
    elif [ -f "$f" ]; then
      printf '  %s %s\n' "$f" "$(cksum < "$f")"
    fi
  done)
}

# installed_is <source>: the installed launcher and tree are that source's, byte for byte
installed_is() {
  [ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ] && same "$HA_BIN" "$1/bin/herdr-agent" &&
    [ "$(tree_shape "$HA_SHARE/")" = "$(tree_shape "$1/share/herdr-agent")" ]
}

trees() { find "$SHARE_DIR" -maxdepth 1 -name 'herdr-agent@*' -type d 2> /dev/null | wc -l | tr -d ' '; }
no_temp() { [ -z "$(find "$BIN_DIR" "$SHARE_DIR" -maxdepth 1 -name '.herdr-agent.*' 2> /dev/null)" ]; }
herdr_sum() { cksum < "$TARGET" 2> /dev/null; }
no_session_lines() { ! grep -q ' session ' "$LOG" 2> /dev/null; }

# ha_reset: no herdr-agent at all, as on a machine that never had one
ha_reset() {
  rm -rf "$HA_BIN" "$HA_PREV" "$HA_SHARE" "$HA_SHARE_PREV" "$SHARE_DIR"/herdr-agent@*
}

# The pre-9.2 layout as a stand-in: a launcher that answers --help and whose install
# links ~/.local/bin/herdr-agent to itself, with a tree beside it, both marked
# `dotfiles`. ~/.local/bin/herdr-agent starts as a link to it
dotfiles_layout() {
  local dot="$BASE/dotfiles/zsh/.local" a
  mkdir -p "$dot/bin" "$dot/share/herdr-agent/bin"
  # shellcheck disable=SC2016  # the stand-in's own zsh
  printf '%s\n' '#!/bin/zsh -f' '# herdr-agent stand-in for the layout before the copy-install' '# variant dotfiles' \
    'self=${0:A}' 'invoked=${0:t}' 'links=${self:h:h}/share/herdr-agent/bin' \
    'case $invoked in (claude|codex|pi|agy) print -r -- "stand-in $invoked"; exit 0 ;; esac' \
    'case ${1:-} in' \
    '  (install) mkdir -p -- $HOME/.local/bin && ln -sfn -- $self $HOME/.local/bin/herdr-agent ;;' \
    '  (-h|--help|help) print -r -- "herdr-agent (dotfiles stand-in)" ;;' \
    '  (*) print -ru2 -- "unknown command: $1"; exit 1 ;;' \
    'esac' > "$dot/bin/herdr-agent"
  printf '%s\n' '#!/bin/zsh -f' '# variant dotfiles' 'exit 0' > "$dot/share/herdr-agent/hook-cmux"
  chmod 755 "$dot/bin/herdr-agent" "$dot/share/herdr-agent/hook-cmux"
  for a in claude codex pi agy; do ln -s ../../../bin/herdr-agent "$dot/share/herdr-agent/bin/$a"; done
  ln -s "$dot/bin/herdr-agent" "$HA_BIN"
  DOT_LAUNCHER="$dot/bin/herdr-agent"
}

dotfiles_sum() { (cd "$BASE/dotfiles" && find . -print | LC_ALL=C sort | while IFS= read -r f; do
  if [ -L "$f" ]; then printf '%s -> %s\n' "$f" "$(readlink "$f")"; elif [ -f "$f" ]; then printf '%s %s\n' "$f" "$(cksum < "$f")"; fi
done); }

# ha_background <out> [env assignments...] -- [args...]: the installer as a background
# job whose $! is the script itself (exec), for signals
ha_background() {
  local out="$1"
  shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    envs+=("$1")
    shift
  done
  [ "${1:-}" = -- ] && shift
  (isolated_exec RBF_INSTALL_PREBUILT="$BUILD" ${envs[@]+"${envs[@]}"} "$INSTALL" "$@" > "$out.stdout" 2> "$out") &
  HA_BG_PID=$!
}

# wait_until <tenths> <command...>
wait_until() {
  local n="$1"
  shift
  while [ "$n" -gt 0 ]; do
    "$@" && return 0
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}

staged_exists() { [ -n "$(find "$BIN_DIR" -maxdepth 1 -name '.herdr-agent.staged.*' 2> /dev/null)" ]; }
prepared_exists() { [ -n "$(find "$BIN_DIR" -maxdepth 1 -name '.herdr-agent.prev.*' 2> /dev/null)" ]; }
share_moved_from() { [ "$(readlink "$HA_SHARE" 2> /dev/null)" != "$1" ]; }

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_install() {
  local a out="$BASE/ha-install.err" rc
  a="$(ha_source A)"
  ha_run "$out" "$a" -- --herdr-agent
  rc=$?
  check "exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "~/.local/bin/herdr-agent is a regular file" eval '[ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ]'
  check "~/.local/share/herdr-agent is a link to herdr-agent@<time> ($(readlink "$HA_SHARE"))" \
    eval 'case "$(readlink "$HA_SHARE")" in herdr-agent@*) [ -d "$HA_SHARE/" ] ;; *) false ;; esac'
  check "bin/claude resolves to ~/.local/bin/herdr-agent" \
    [ "$(/bin/zsh -fc 'print -r -- ${1:A}' ha "$HA_SHARE/bin/claude")" = "$(cd "$BIN_DIR" && pwd -P)/herdr-agent" ]
  check "~/.local/bin/herdr-agent --help exits 0" eval 'isolated_env "$HA_BIN" --help > /dev/null 2>&1'
  check "A's launcher and tree, byte for byte" installed_is "$a"
  check "the pair is consistent (A/A; got $(ha_pair))" consistent_as A
  check "no previous on a clean home" eval '[ ! -e "$HA_PREV" ] && [ ! -L "$HA_PREV" ] && [ ! -L "$HA_SHARE_PREV" ]'
  check "step line" has "$out" "✓ installed herdr-agent (rbf "
  check "summary" has "$out" "✓ installed herdr-agent; running agents keep the copy they started with"
  check "rollback row" has "$out" "rollback     rbf/scripts/install-rbf.sh --herdr-agent --rollback"
  check "log names the tree" grep -q ' installed herdr-agent herdr-agent@' "$LOG"
  check "no temporary files left" no_temp
  check "nothing on stdout" [ ! -s "$out.stdout" ]
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_only() {
  install_old
  local a out="$BASE/ha-only.err" rc before
  a="$(ha_source A)"
  printf '#!/bin/sh\ntouch "%s"\n' "$BASE/work/cargo-ran" > "$BASE/recording-cargo"
  chmod +x "$BASE/recording-cargo"
  before="$(herdr_sum)"
  isolated_env RBF_INSTALL_CARGO="$BASE/recording-cargo" RBF_INSTALL_HERDR_AGENT_SRC="$a" "$INSTALL" --herdr-agent \
    > "$out.stdout" 2> "$out"
  rc=$?
  check "exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "the cargo stand-in never ran" [ ! -e "$BASE/work/cargo-ran" ]
  check "herdr byte-identical" [ "$before" = "$(herdr_sum)" ]
  check "no herdr.previous written" [ ! -e "$PREVIOUS" ]
  check "no session handed off (no handoff line)" has_not "$out" "handing off"
  check "no session handed off (no session in the log)" no_session_lines
  check "plan heading" has "$out" "herdr-rbf install plan — herdr-agent only"
  check "plan: herdr not touched" has "$out" "  herdr          not touched; no build, no session handed off"
  check "herdr-agent is A" installed_is "$a"

  # off PATH, the warning names what this mode installs
  out="$BASE/ha-only-no-path.err"
  isolated_env PATH="$PYTHON_DIR:$JJ_DIR:/usr/bin:/bin:/usr/sbin:/sbin" RBF_INSTALL_HERDR_AGENT_SRC="$a" "$INSTALL" --herdr-agent --dry-run \
    > "$out.stdout" 2> "$out"
  check "PATH warning names herdr-agent" has "$out" "⚠ ~/.local/bin is not on PATH; typing herdr-agent won't find this install"
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_rollback() {
  install_old
  local a b out rc before
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  ha_run "$BASE/ha-b.err" "$b" -- --herdr-agent
  check "install B exit 0" [ $? -eq 0 ]
  check "B installed" installed_is "$b"
  before="$(herdr_sum)"

  out="$BASE/ha-rollback-1.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "rollback exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "A's launcher and tree back, byte for byte" installed_is "$a"
  check "the pair is consistent (A/A; got $(ha_pair))" consistent_as A
  check "B kept as herdr-agent.previous" same "$HA_PREV" "$b/bin/herdr-agent"
  check "step line" has "$out" "✓ rolled back herdr-agent (from herdr-agent.previous)"
  check "summary" has "$out" "✓ rolled back herdr-agent; running agents keep the copy they started with"
  check "plan: previous is exchanged" has "$out" "                 previous  the current one, kept as herdr-agent.previous"

  out="$BASE/ha-rollback-2.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "second rollback exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "B back, byte for byte" installed_is "$b"
  check "the pair is consistent (B/B; got $(ha_pair))" consistent_as B
  check "herdr untouched" [ "$before" = "$(herdr_sum)" ]
  check "no herdr.previous written" [ ! -e "$PREVIOUS" ]
  check "no session handed off" no_session_lines
  check "no temporary files left" no_temp
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_no_previous() {
  local a out rc before
  a="$(ha_source A)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]

  before="$(ha_state)"
  out="$BASE/ha-no-previous.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "no previous: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "no previous: plan row" has "$out" "  herdr-agent    from      nothing: no herdr-agent.previous"
  check "no previous: message" has "$out" "✗ no previous herdr-agent at ~/.local/bin/herdr-agent.previous; nothing changed"
  check "no previous: nothing changed" [ "$before" = "$(ha_state)" ]

  # An install never leaves this state, so it's made by hand
  /bin/cp -P "$HA_BIN" "$HA_PREV"
  ln -s "$(readlink "$HA_SHARE")" "$HA_SHARE_PREV"
  before="$(ha_state)"
  out="$BASE/ha-same-previous.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "same previous: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "same previous: message" has "$out" "✗ ~/.local/bin/herdr-agent.previous is the same as herdr-agent; nothing to roll back"
  check "same previous: nothing changed" [ "$before" = "$(ha_state)" ]
}

# Scenario 8: a loop checks every millisecond that the hook shim, the launcher and an
# agent link resolve, through 20 alternating installs and rollbacks
# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_no_gap() {
  local a b rc op watcher probes ops=0 bad=0
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-first.err" "$a" -- --herdr-agent
  check "first install exit 0" [ $? -eq 0 ]
  : > "$BASE/work/missing"
  # no sleep between rounds: a link renamed over a link is missing for microseconds, which
  # a paced watcher rarely lands in
  perl -e '
    my ($miss, $count, @paths) = @ARGV;
    my $n = 0;
    $SIG{TERM} = sub { open my $c, ">", $count; print $c "$n\n"; close $c; exit 0 };
    while (1) {
      for my $p (@paths) {
        next if -x $p;
        open my $m, ">>", $miss; print $m "$n $p\n"; close $m;
      }
      $n++;
    }' "$BASE/work/missing" "$BASE/work/probes" "$HA_SHARE/hook-cmux" "$HA_BIN" "$HA_SHARE/bin/claude" &
  watcher=$!
  sleep 0.5
  for _ in 1 2 3 4 5; do
    for op in B rollback rollback A; do
      case "$op" in
        A) ha_run "$BASE/ha-op.err" "$a" -- --herdr-agent ;;
        B) ha_run "$BASE/ha-op.err" "$b" -- --herdr-agent ;;
        rollback) run_install "$BASE/ha-op.err" -- --herdr-agent --rollback ;;
      esac
      rc=$?
      ops=$((ops + 1))
      [ "$rc" -eq 0 ] || { bad=$((bad + 1)); note "op $ops ($op) exit $rc: $(tail -2 "$BASE/ha-op.err" | tr '\n' ' ')"; }
    done
  done
  sleep 0.5
  kill -TERM "$watcher" 2> /dev/null
  wait "$watcher" 2> /dev/null
  probes="$(cat "$BASE/work/probes" 2> /dev/null)"
  note "$ops operations, $probes probe rounds"
  check "20 operations, every one exit 0 ($bad failed)" eval '[ "$ops" -eq 20 ] && [ "$bad" -eq 0 ]'
  check "the watcher ran through them (${probes:-0} rounds)" [ "${probes:-0}" -gt 1000 ]
  check "no path was ever missing ($(wc -l < "$BASE/work/missing" | tr -d ' ') misses)" [ ! -s "$BASE/work/missing" ]
  check "at most two herdr-agent@ trees ($(trees))" [ "$(trees)" -le 2 ]
  check "A installed at the end, consistent (got $(ha_pair))" eval 'installed_is "$a" && consistent_as A'
  check "no temporary files left" no_temp
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_refuse() {
  local a broken out rc before
  a="$(ha_source A)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  before="$(ha_state)"

  broken="$(ha_source broken-launcher)"
  printf '}\n' >> "$broken/bin/herdr-agent"
  out="$BASE/ha-refuse-launcher.err"
  ha_run "$out" "$broken" -- --herdr-agent
  rc=$?
  check "launcher doesn't parse: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "launcher doesn't parse: message" has "$out" "✗ staged herdr-agent doesn't parse; herdr-agent unchanged"
  check "launcher doesn't parse: the reason names the launcher" grep -q '^  herdr-agent:[0-9]*: parse error' "$out"
  check "launcher doesn't parse: installed copy unchanged" [ "$before" = "$(ha_state)" ]

  broken="$(ha_source broken-shim)"
  printf '}\n' >> "$broken/share/herdr-agent/hook-cmux"
  out="$BASE/ha-refuse-shim.err"
  ha_run "$out" "$broken" -- --herdr-agent
  rc=$?
  check "hook-cmux doesn't parse: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "hook-cmux doesn't parse: message" has "$out" "✗ staged hook-cmux doesn't parse; herdr-agent unchanged"
  check "hook-cmux doesn't parse: the reason names hook-cmux" grep -q '^  hook-cmux:[0-9]*: parse error' "$out"
  check "hook-cmux doesn't parse: installed copy unchanged" [ "$before" = "$(ha_state)" ]

  broken="$(ha_source broken-link)"
  ln -sfn ../bin/herdr-agent "$broken/share/herdr-agent/bin/claude"
  out="$BASE/ha-refuse-link.err"
  ha_run "$out" "$broken" -- --herdr-agent
  rc=$?
  check "agent link wrong: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "agent link wrong: message" has "$out" "✗ staged bin/claude points at ../bin/herdr-agent, not ../../../bin/herdr-agent; herdr-agent unchanged"
  check "agent link wrong: installed copy unchanged" [ "$before" = "$(ha_state)" ]

  broken="$(ha_source broken-help)"
  # parses, but exits 1 before it can answer --help
  { head -1 "$broken/bin/herdr-agent"; printf 'exit 1\n'; tail -n +2 "$broken/bin/herdr-agent"; } > "$BASE/work/help-broken"
  cat "$BASE/work/help-broken" > "$broken/bin/herdr-agent"
  out="$BASE/ha-refuse-help.err"
  ha_run "$out" "$broken" -- --herdr-agent
  rc=$?
  check "--help fails: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "--help fails: message" has "$out" "✗ staged herdr-agent --help exited 1; herdr-agent unchanged"
  check "--help fails: installed copy unchanged" [ "$before" = "$(ha_state)" ]
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_same_build() {
  local a b out rc before
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  ha_run "$BASE/ha-b.err" "$b" -- --herdr-agent
  check "install B exit 0" [ $? -eq 0 ]
  before="$(ha_state)"

  out="$BASE/ha-same-dry.err"
  ha_run "$out" "$b" -- --herdr-agent --dry-run
  check "dry run: plan says same as installed" has "$out" "  herdr-agent    same as installed; nothing to change"

  out="$BASE/ha-same.err"
  ha_run "$out" "$b" -- --herdr-agent
  rc=$?
  check "second install of B: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "step line" has "$out" "✓ herdr-agent unchanged (same as installed)"
  check "summary" has "$out" "✓ nothing to install; herdr-agent is already this copy"
  check "no rollback row" has_not "$out" "rollback     "
  check "no new tree, .previous where it was, nothing else changed" [ "$before" = "$(ha_state)" ]
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_after_build() {
  install_old
  local a b out rc before_herdr before_ha
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  start_sessions default work

  out="$BASE/ha-plain.err"
  ha_run "$out" "$b" --
  rc=$?
  check "plain install: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "herdr is the build" same "$TARGET" "$BUILD"
  check "herdr-agent is B" installed_is "$b"
  check "the pair is consistent (B/B; got $(ha_pair))" consistent_as B
  check "default handed off" has "$out" "✓ default    handed off; pane processes still running"
  check "work handed off" has "$out" "✓ work       handed off; pane processes still running"
  check "herdr-agent after herdr, before any handoff" eval \
    '[ "$(grep -n "✓ installed herdr-agent" "$out" | cut -d: -f1)" -gt "$(grep -n "✓ installed herdr 0" "$out" | cut -d: -f1)" ] &&
     [ "$(grep -n "✓ installed herdr-agent" "$out" | cut -d: -f1)" -lt "$(grep -n "⋯ handing off" "$out" | head -1 | cut -d: -f1)" ]'
  check "summary" has "$out" "✓ installed herdr and herdr-agent; 2 of 2 sessions handed off"
  check "rollback row for herdr" has "$out" "rollback     herdr        rbf/scripts/install-rbf.sh --rollback"
  check "rollback row for herdr-agent" has "$out" "             herdr-agent  rbf/scripts/install-rbf.sh --herdr-agent --rollback"
  check "loops alive" loops_alive default work

  before_herdr="$(herdr_sum)"
  before_ha="$(ha_state)"
  out="$BASE/ha-build-failed.err"
  isolated_env RBF_INSTALL_CARGO=/usr/bin/false RBF_INSTALL_HERDR_AGENT_SRC="$a" "$INSTALL" > "$out.stdout" 2> "$out"
  rc=$?
  check "failed build: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "failed build: message" has "$out" "✗ build failed; nothing was written to ~/.local/bin"
  check "failed build: herdr byte-identical" [ "$before_herdr" = "$(herdr_sum)" ]
  check "failed build: herdr-agent byte-identical" [ "$before_ha" = "$(ha_state)" ]
  check "failed build: no herdr-agent step" has_not "$out" "⋯ staging herdr-agent"
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_interrupted() {
  local a b out rc before
  a="$(ha_source A)"
  b="$(ha_source B)"
  # A installed over B, so both .previous entries exist to be kept
  ha_run "$BASE/ha-b.err" "$b" -- --herdr-agent
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "setup: A installed, B previous" eval 'installed_is "$a" && same "$HA_PREV" "$b/bin/herdr-agent" && [ -L "$HA_SHARE_PREV" ]'

  before="$(ha_state)"
  out="$BASE/ha-int-staged.err"
  ha_background "$out" RBF_INSTALL_HERDR_AGENT_SRC="$b" RBF_INSTALL_HERDR_AGENT_PAUSE=staged:5 -- --herdr-agent
  check "staged: the stage exists before TERM" wait_until 100 staged_exists
  kill -TERM "$HA_BG_PID"
  wait "$HA_BG_PID"
  rc=$?
  check "staged: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "staged: message" has "$out" "✗ interrupted; herdr-agent unchanged"
  check "staged: launcher, tree, .previous and no stage left, all as before" [ "$before" = "$(ha_state)" ]

  out="$BASE/ha-int-prepared.err"
  ha_background "$out" RBF_INSTALL_HERDR_AGENT_SRC="$b" RBF_INSTALL_HERDR_AGENT_PAUSE=prepared:5 -- --herdr-agent
  check "prepared: the outgoing copy exists before TERM" wait_until 100 prepared_exists
  kill -TERM "$HA_BG_PID"
  wait "$HA_BG_PID"
  rc=$?
  check "prepared: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "prepared: message" has "$out" "✗ interrupted; herdr-agent unchanged"
  check "prepared: both .previous entries as before, no .prev or .prevlink left" [ "$before" = "$(ha_state)" ]

  local link_before
  link_before="$(readlink "$HA_SHARE")"
  out="$BASE/ha-int-renames.err"
  ha_background "$out" RBF_INSTALL_HERDR_AGENT_SRC="$b" RBF_INSTALL_HERDR_AGENT_PAUSE=renames:3 -- --herdr-agent
  check "renames: TERM sent between the two renames" wait_until 100 share_moved_from "$link_before"
  kill -TERM "$HA_BG_PID"
  wait "$HA_BG_PID"
  rc=$?
  check "renames: the signal is ignored, exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "renames: B installed" installed_is "$b"
  check "renames: the pair is consistent (B/B; got $(ha_pair))" consistent_as B
  check "renames: summary" has "$out" "✓ installed herdr-agent; running agents keep the copy they started with"
  check "renames: no temporary files left" no_temp
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_first_install() {
  local a out rc before
  dotfiles_layout
  a="$(ha_source A)"
  before="$(dotfiles_sum)"
  out="$BASE/ha-first.err"
  ha_run "$out" "$a" -- --herdr-agent
  rc=$?
  check "exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "plan: the link is kept as it is" has "$out" "                 previous  kept as herdr-agent.previous (a link, as it is now)"
  check "the launcher is a regular file" eval '[ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ]'
  check "the share link is created" eval '[ -L "$HA_SHARE" ] && [ -d "$HA_SHARE/" ]'
  check "herdr-agent.previous is the old link itself ($(readlink "$HA_PREV"))" \
    eval '[ -L "$HA_PREV" ] && [ "$(readlink "$HA_PREV")" = "$DOT_LAUNCHER" ]'
  check "no previous tree" eval '[ ! -e "$HA_SHARE_PREV" ] && [ ! -L "$HA_SHARE_PREV" ]'
  check "the dotfiles-like copy is byte-identical" [ "$before" = "$(dotfiles_sum)" ]
  check "the pair is consistent (A/A; got $(ha_pair))" consistent_as A
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_no_relink() {
  local a out rc before
  a="$(ha_source A)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  before="$(ha_state)"

  out="$BASE/ha-cmux-restart.out"
  isolated_env "$HA_SRC_REPO/bin/herdr-agent" cmux-restart > "$out" 2>&1
  rc=$?
  check "cmux-restart from the checkout: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "~/.local/bin/herdr-agent still a regular file, byte-identical" \
    eval '[ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ] && [ "$before" = "$(ha_state)" ]'
  check "its output is about cmux's restart entries ($(head -1 "$out"))" grep -q 'cmux restart entries' "$out"
  check "its output links nothing (no \"linked\" line)" has_not "$out" "linked "
  check "it's the only line" [ "$(grep -c . "$out")" -eq 1 ]

  out="$BASE/ha-install-cmd.out"
  isolated_env "$HA_SRC_REPO/bin/herdr-agent" install > "$out" 2>&1
  rc=$?
  check "herdr-agent install: refused (exit $rc)" [ "$rc" -ne 0 ]
  check "herdr-agent install: as an unknown command" has "$out" "unknown command: install"
  check "herdr-agent install: nothing changed" [ "$before" = "$(ha_state)" ]
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_offline() {
  local a rc
  a="$(ha_source A)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  /bin/mv "$a" "$a.away"
  check "the source is gone" [ ! -e "$a" ]
  isolated_env "$HA_BIN" status > "$BASE/ha-status.out" 2>&1
  rc=$?
  check "herdr-agent status exits 0 (got $rc)" [ "$rc" -eq 0 ]
  check "status names the installed shim" has "$BASE/ha-status.out" "routed through $HA_SHARE/hook-cmux"
  check "zsh -n on the installed hook-cmux" /bin/zsh -n "$HA_SHARE/hook-cmux"
  check "nothing installed resolves into the source" eval \
    '! grep -rqF "$a" "$HA_BIN" "$HA_SHARE/" && [ "$(/bin/zsh -fc "print -r -- \${1:A}" ha "$HA_SHARE/bin/claude")" = "$(cd "$BIN_DIR" && pwd -P)/herdr-agent" ]'
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_first_rollback() {
  install_old
  local a out rc before_herdr tree_a
  dotfiles_layout
  a="$(ha_source A)"
  before_herdr="$(herdr_sum)"
  check "start: the pair is the dotfiles one (got $(ha_pair))" consistent_as dotfiles

  ha_run "$BASE/ha-first.err" "$a" -- --herdr-agent
  rc=$?
  check "first install: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "first install: consistent (A/A; got $(ha_pair))" consistent_as A
  tree_a="$(readlink "$HA_SHARE")"

  out="$BASE/ha-rollback-1.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "first rollback: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "first rollback: the plan names the link's target" has "$out" "                           $DOT_LAUNCHER"
  check "first rollback: the plan's support row" has "$out" "                 support   the files beside that link's target"
  check "first rollback: ~/.local/bin/herdr-agent is the link into the stand-in again" \
    eval '[ -L "$HA_BIN" ] && [ "$(readlink "$HA_BIN")" = "$DOT_LAUNCHER" ]'
  check "first rollback: --help exits 0" eval 'isolated_env "$HA_BIN" --help > /dev/null 2>&1'
  check "first rollback: consistent (dotfiles/dotfiles; got $(ha_pair))" consistent_as dotfiles
  check "first rollback: the share link stays on tree A" [ "$(readlink "$HA_SHARE")" = "$tree_a" ]
  isolated_env "$HA_BIN" install > /dev/null 2>&1
  check "the old install through it leaves the link a link into the stand-in, not to itself" \
    eval '[ -L "$HA_BIN" ] && [ "$(readlink "$HA_BIN")" = "$DOT_LAUNCHER" ] && isolated_env "$HA_BIN" --help > /dev/null 2>&1'

  out="$BASE/ha-rollback-2.err"
  run_install "$out" -- --herdr-agent --rollback
  rc=$?
  check "second rollback: exit 0 (got $rc)" [ "$rc" -eq 0 ]
  check "second rollback: launcher A is back" eval '[ -f "$HA_BIN" ] && [ ! -L "$HA_BIN" ] && same "$HA_BIN" "$a/bin/herdr-agent"'
  check "second rollback: the share link still names tree A" [ "$(readlink "$HA_SHARE")" = "$tree_a" ]
  check "second rollback: consistent (A/A; got $(ha_pair))" consistent_as A
  check "second rollback: both contract paths resolve" eval '[ -x "$HA_BIN" ] && [ -x "$HA_SHARE/hook-cmux" ]'
  check "herdr untouched" [ "$before_herdr" = "$(herdr_sum)" ]
}

# jq-less PATH: links to every tool the installer and the launcher use, jq left out
nojq_path() {
  local dir="$BASE/nojq-bin" tool
  mkdir -p "$dir"
  for tool in basename cat chmod cksum cmp cp cut date dirname env find grep head jj ln mkdir mktemp mv paste \
    perl python3 readlink rm sed shasum sleep sort stat tail tr wc zsh awk; do
    ln -sf "$(command -v "$tool")" "$dir/$tool"
  done
  printf '%s' "$dir"
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_exit_3() {
  local a broken out rc dir before_ha
  a="$(ha_source A)"
  dir="$(nojq_path)"
  check "the jq-less PATH has no jq" [ ! -e "$dir/jq" ]
  out="$BASE/ha-nojq.err"
  isolated_env PATH="$dir" RBF_INSTALL_HERDR_AGENT_SRC="$a" "$INSTALL" --herdr-agent > "$out.stdout" 2> "$out"
  rc=$?
  check "no jq: exit 3 (got $rc)" [ "$rc" -eq 3 ]
  check "no jq: herdr-agent installed" installed_is "$a"
  check "no jq: plan row" has "$out" "                 cmux      can't check: jq not found"
  check "no jq: warning" has "$out" "⚠ cmux restart entries not checked; jq not found"
  check "no jq: summary" has "$out" "⚠ installed herdr-agent"
  check "no jq: finish row" has "$out" "finish       brew install jq, then herdr-agent cmux-restart"

  # the restart-entry step itself failing: the launcher's reason reaches the warning
  local b restart="$BASE/.config/cmux/restart-commands.json"
  b="$(ha_source B)"
  printf '{}\n' > "$restart"
  out="$BASE/ha-restart-fails.err"
  ha_run "$out" "$b" -- --herdr-agent
  rc=$?
  check "restart fails: exit 3 (got $rc)" [ "$rc" -eq 3 ]
  check "restart fails: herdr-agent installed" installed_is "$b"
  check "restart fails: the reason, not the generic line" has "$out" \
    "⚠ cmux restart entries not added; ~/.config/cmux/restart-commands.json isn't a restart-commands file cmux can read; add herdr-agent-attach by hand"
  check "restart fails: finish row" has "$out" "finish       herdr-agent cmux-restart"
  check "restart fails: the file left alone" [ "$(cat "$restart")" = "{}" ]

  install_old
  start_sessions default work
  before_ha="$(ha_state)"
  broken="$(ha_source broken-shim)"
  printf '}\n' >> "$broken/share/herdr-agent/hook-cmux"
  out="$BASE/ha-plain-broken.err"
  ha_run "$out" "$broken" --
  rc=$?
  check "broken herdr-agent in a plain install: exit 3 (got $rc)" [ "$rc" -eq 3 ]
  check "herdr installed" same "$TARGET" "$BUILD"
  check "herdr-agent byte-identical" [ "$before_ha" = "$(ha_state)" ]
  check "warning, not failure" has "$out" "⚠ staged hook-cmux doesn't parse; herdr-agent unchanged"
  check "default still handed off" has "$out" "✓ default    handed off; pane processes still running"
  check "work still handed off" has "$out" "✓ work       handed off; pane processes still running"
  check "summary" has "$out" "⚠ installed herdr, not herdr-agent; 2 of 2 sessions handed off"
  check "finish row" has "$out" "finish       rbf/scripts/install-rbf.sh --herdr-agent"
  check "herdr's rollback row only" eval 'has "$out" "rollback     rbf/scripts/install-rbf.sh --rollback" && has_not "$out" "--herdr-agent --rollback"'
  check "loops alive" loops_alive default work
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_interrupted_plain() {
  local a b out rc before_ha herdr_in
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "install A exit 0" [ $? -eq 0 ]
  install_old
  start_sessions default work
  before_ha="$(ha_state)"
  out="$BASE/ha-int-plain.err"
  ha_background "$out" RBF_INSTALL_HERDR_AGENT_SRC="$b" RBF_INSTALL_HERDR_AGENT_PAUSE=staged:10 --
  check "the herdr-agent stage exists before TERM" wait_until 300 staged_exists
  herdr_in=0
  same "$TARGET" "$BUILD" && herdr_in=1
  check "herdr was already swapped when TERM was sent" [ "$herdr_in" = 1 ]
  kill -TERM "$HA_BG_PID"
  wait "$HA_BG_PID"
  rc=$?
  check "exit 3 (got $rc)" [ "$rc" -eq 3 ]
  check "message" has "$out" "✗ interrupted; herdr is installed, herdr-agent unchanged"
  check "herdr is the new build" same "$TARGET" "$BUILD"
  check "herdr-agent launcher, tree, no stage left: as before" [ "$before_ha" = "$(ha_state)" ]
  check "default handed off" has "$out" "✓ default    handed off; pane processes still running"
  check "work handed off" has "$out" "✓ work       handed off; pane processes still running"
  check "summary" has "$out" "⚠ installed herdr, not herdr-agent; 2 of 2 sessions handed off"
  check "finish row" has "$out" "finish       rbf/scripts/install-rbf.sh --herdr-agent"
  check "log ends with exit 3" [ "$(tail -1 "$LOG" | sed 's/.* exit //')" = 3 ]
  check "loops alive" loops_alive default work
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_undo() {
  local a b out rc before
  a="$(ha_source A)"
  b="$(ha_source B)"
  ha_run "$BASE/ha-b.err" "$b" -- --herdr-agent
  ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
  check "setup: A installed over B" eval 'installed_is "$a" && [ -L "$HA_SHARE_PREV" ]'
  before="$(ha_state)"
  out="$BASE/ha-undo.err"
  ha_run "$out" "$b" RBF_INSTALL_HERDR_AGENT_FAIL=rename2 -- --herdr-agent
  rc=$?
  check "over A: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "over A: message" has "$out" "✗ couldn't replace ~/.local/bin/herdr-agent; herdr-agent unchanged"
  check "over A: share link on tree A, launcher A, both .previous, trees and no temp files as before" \
    [ "$before" = "$(ha_state)" ]
  check "over A: consistent (A/A; got $(ha_pair))" consistent_as A

  ha_reset
  dotfiles_layout
  out="$BASE/ha-undo-first.err"
  ha_run "$out" "$a" RBF_INSTALL_HERDR_AGENT_FAIL=rename2 -- --herdr-agent
  rc=$?
  check "first install: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "first install: message" has "$out" "✗ couldn't replace ~/.local/bin/herdr-agent; herdr-agent unchanged"
  check "first install: no share link" eval '[ ! -e "$HA_SHARE" ] && [ ! -L "$HA_SHARE" ]'
  check "first install: the launcher is still the link into the stand-in" \
    eval '[ -L "$HA_BIN" ] && [ "$(readlink "$HA_BIN")" = "$DOT_LAUNCHER" ]'
  check "first install: no .previous" eval '[ ! -e "$HA_PREV" ] && [ ! -L "$HA_PREV" ] && [ ! -L "$HA_SHARE_PREV" ]'
  check "first install: no tree ($(trees))" [ "$(trees)" -eq 0 ]
  check "first install: no temporary files left" no_temp

  # the rollback's own step 2 failing: the share link goes back, nothing else moves
  ha_reset
  rm -f "$HA_BIN"
  ha_run "$BASE/ha-a2.err" "$a" -- --herdr-agent
  ha_run "$BASE/ha-b2.err" "$b" -- --herdr-agent
  check "rollback: setup B installed over A" eval 'installed_is "$b" && [ -L "$HA_SHARE_PREV" ]'
  before="$(ha_state)"
  out="$BASE/ha-undo-rollback.err"
  run_install "$out" RBF_INSTALL_HERDR_AGENT_FAIL=rename2 -- --herdr-agent --rollback
  rc=$?
  check "rollback: exit 1 (got $rc)" [ "$rc" -eq 1 ]
  check "rollback: message" has "$out" "✗ couldn't restore ~/.local/bin/herdr-agent; herdr-agent unchanged"
  check "rollback: launchers, share links, trees as before" [ "$before" = "$(ha_state)" ]
  check "rollback: consistent (B/B; got $(ha_pair))" consistent_as B
  check "rollback: no temporary files left" no_temp
}

# shellcheck disable=SC2016,SC2088  # conditions are evaluated by check; ~ paths are labels
case_herdr_agent_previous_fails() {
  local a b z out rc step tree_a before pair
  a="$(ha_source A)"
  b="$(ha_source B)"
  z="$(ha_source Z)"
  for step in rename3 rename4; do
    ha_reset
    # Z then A, so a .previous pair (Z/Z) exists that a half-kept A could be mixed with
    ha_run "$BASE/ha-z.err" "$z" -- --herdr-agent
    ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
    tree_a="$(readlink "$HA_SHARE")"
    out="$BASE/ha-$step.err"
    ha_run "$out" "$b" RBF_INSTALL_HERDR_AGENT_FAIL="$step" -- --herdr-agent
    rc=$?
    check "$step: exit 3 (got $rc)" [ "$rc" -eq 3 ]
    check "$step: B installed" installed_is "$b"
    check "$step: consistent (B/B; got $(ha_pair))" consistent_as B
    [ "$step" = rename3 ] &&
      check "$step: warning" has "$out" "⚠ couldn't keep the previous herdr-agent as herdr-agent.previous"
    if [ "$step" = rename3 ]; then
      check "$step: summary" has "$out" "⚠ installed herdr-agent; rollback target not updated"
    else
      check "$step: summary" has "$out" "⚠ installed herdr-agent; rollback target removed"
    fi
    check "$step: no rollback row" has_not "$out" "rollback     "
    check "$step: tree A still exists (prune skipped)" [ -d "$SHARE_DIR/$tree_a" ]
    check "$step: no .prev or .prevlink left" no_temp
    # whatever .previous is left must be a pair a rollback can install, or nothing at all
    before="$(ha_state)"
    run_install "$BASE/ha-$step-rollback.err" -- --herdr-agent --rollback
    rc=$?
    if [ "$step" = rename4 ]; then
      check "$step: the half-kept launcher is removed, not left beside the older tree" \
        eval '[ ! -e "$HA_PREV" ] && [ ! -L "$HA_PREV" ]'
      check "$step: warning says the target is removed" has "$out" "⚠ couldn't keep the previous herdr-agent; rollback target removed"
      check "$step: and what that means" has "$out" "  --herdr-agent --rollback has nothing to restore until the next install"
      check "$step: a rollback refuses (exit $rc)" [ "$rc" -eq 1 ]
      check "$step: with no previous herdr-agent" has "$BASE/ha-$step-rollback.err" "✗ no previous herdr-agent at ~/.local/bin/herdr-agent.previous; nothing changed"
      check "$step: and changes nothing" [ "$before" = "$(ha_state)" ]
    else
      pair="$(ha_pair)"
      check "$step: a rollback installs the older pair, consistent (exit $rc, got $pair)" \
        eval '[ "$rc" -eq 0 ] && [ "$pair" = Z/Z ]'
    fi
  done

  # the rollback's own step 3 or 4 failing: its step 2 used up .previous, so no older
  # pair is left, and nothing may be left that a second rollback installs as a mixed pair
  for step in rename3 rename4; do
    ha_reset
    ha_run "$BASE/ha-a.err" "$a" -- --herdr-agent
    ha_run "$BASE/ha-b.err" "$b" -- --herdr-agent
    out="$BASE/ha-rollback-$step.err"
    run_install "$out" RBF_INSTALL_HERDR_AGENT_FAIL="$step" -- --herdr-agent --rollback
    rc=$?
    check "rollback $step: exit 3 (got $rc)" [ "$rc" -eq 3 ]
    check "rollback $step: A back, consistent (A/A; got $(ha_pair))" consistent_as A
    check "rollback $step: warning" has "$out" "⚠ couldn't keep the replaced herdr-agent; rollback target removed"
    check "rollback $step: and what that means" has "$out" "  --herdr-agent --rollback has nothing to restore until the next install"
    check "rollback $step: summary" has "$out" "⚠ rolled back herdr-agent; rollback target removed"
    check "rollback $step: no .previous launcher" eval '[ ! -e "$HA_PREV" ] && [ ! -L "$HA_PREV" ]'
    check "rollback $step: no temporary files left" no_temp
    before="$(ha_state)"
    run_install "$BASE/ha-rollback-$step-again.err" -- --herdr-agent --rollback
    rc=$?
    check "rollback $step: a second rollback refuses (exit $rc)" [ "$rc" -eq 1 ]
    check "rollback $step: and changes nothing" [ "$before" = "$(ha_state)" ]
  done
}

# ---------------------------------------------------------------------------

case "$CASE" in
  dry-run | install | hosting | failed-handoff | interrupted-handoff | classify | rollback | refusals | first-install | path-shadow | alt-screen | attached-window | wedged | real-agent | busy-shell | \
    herdr-agent-install | herdr-agent-only | herdr-agent-rollback | herdr-agent-no-previous | herdr-agent-no-gap | \
    herdr-agent-refuse | herdr-agent-same-build | herdr-agent-after-build | herdr-agent-interrupted | \
    herdr-agent-first-install | herdr-agent-no-relink | herdr-agent-offline | herdr-agent-first-rollback | \
    herdr-agent-exit-3 | herdr-agent-interrupted-plain | herdr-agent-undo | herdr-agent-previous-fails) ;;
  *)
    echo "usage: rbf/scripts/install-rbf.test.sh <dry-run|install|hosting|failed-handoff|interrupted-handoff|classify|rollback|refusals|first-install|path-shadow|alt-screen|attached-window|wedged|real-agent|busy-shell|herdr-agent-install|herdr-agent-only|herdr-agent-rollback|herdr-agent-no-previous|herdr-agent-no-gap|herdr-agent-refuse|herdr-agent-same-build|herdr-agent-after-build|herdr-agent-interrupted|herdr-agent-first-install|herdr-agent-no-relink|herdr-agent-offline|herdr-agent-first-rollback|herdr-agent-exit-3|herdr-agent-interrupted-plain|herdr-agent-undo|herdr-agent-previous-fails>" >&2
    exit 2
    ;;
esac

setup
echo "== $CASE  base=$BASE  build=$("$BUILD" --version)"
"case_${CASE//-/_}"
echo "== $CASE: $FAILS failed"
[ "$FAILS" -eq 0 ]
