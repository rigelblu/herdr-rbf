#!/bin/bash

# Isolated harness for rbf/scripts/install-rbf.sh (hrdr-5 Scenarios 2–10, 12, 13, 15–18).
#
#   rbf/scripts/install-rbf.test.sh <case>
#   cases: dry-run install hosting failed-handoff interrupted-handoff classify rollback refusals first-install
#          path-shadow alt-screen attached-window wedged real-agent busy-shell
#
# Each case gets its own HOME and XDG dirs under /Volumes/tom-ssd/tmp/rbf-h/<case>
# (short, so socket paths stay under macOS's 104 bytes), starts headless sessions from
# an "old" exec wrapper around the build under test, and refuses any socket outside
# that base. Tom's real sessions and ~/.local/bin are never touched.
#
# RBF_TEST_SKIP_BUILD=1 skips the up-front `cargo build --release --locked`.
# bash 3.2 compatible: per-session values live in files.

set -uo pipefail

CASE="${1:-}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$REPO/rbf/scripts/install-rbf.sh"
BUILD="$REPO/target/release/herdr"
BASE="/Volumes/tom-ssd/tmp/rbf-h/$CASE"
BIN_DIR="$BASE/.local/bin"
TARGET="$BIN_DIR/herdr"
PREVIOUS="$BIN_DIR/herdr.previous"
OLD="$BASE/old-herdr"
CONFIG_DIR="$BASE/.config/herdr"
LOG="$BASE/Library/Logs/herdr-rbf-install.log"
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
  case "$BASE" in /Volumes/tom-ssd/tmp/rbf-h/?*) ;; *) echo "bad base: $BASE" >&2; exit 1 ;; esac
  if ! mount | grep -Fq " on /Volumes/tom-ssd ("; then
    echo "external drive not mounted" >&2
    exit 1
  fi
  if [ "${RBF_TEST_SKIP_BUILD:-}" != 1 ]; then
    (cd "$REPO" && cargo build --release --locked) || { echo "build failed" >&2; exit 1; }
  fi
  rm -rf "$BASE"
  mkdir -p "$BIN_DIR" "$CONFIG_DIR" "$BASE/state" "$BASE/run" "$BASE/vars" "$BASE/work"
  printf 'onboarding = false\n\n[update]\nversion_check = false\n' > "$CONFIG_DIR/config.toml"
  : > "$BASE/.zshrc"
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

case_dry_run() {
  install_old
  start_sessions default work
  local before out="$BASE/dry-run.err" rc
  before="$(bin_snapshot)"
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
  check "verdict line" has "$out" "✓ installed; 2 of 2 sessions handed off"
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

  out="$BASE/rollback-2.err"
  run_install "$out" -- --rollback
  rc=$?
  check "second rollback exit 0" [ "$rc" -eq 0 ]
  check "herdr is the build again" same "$TARGET" "$BUILD"
  check "herdr.previous is the old wrapper again" same "$PREVIOUS" "$OLD"
  check "loops alive after second rollback" loops_alive default work
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
  send_line work "$pane" "HOME=/Users/tomhosiawa '$claude_bin' --model haiku 'reply with the word ready'"
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

case "$CASE" in
  dry-run | install | hosting | failed-handoff | interrupted-handoff | classify | rollback | refusals | first-install | path-shadow | alt-screen | attached-window | wedged | real-agent | busy-shell) ;;
  *)
    echo "usage: rbf/scripts/install-rbf.test.sh <dry-run|install|hosting|failed-handoff|interrupted-handoff|classify|rollback|refusals|first-install|path-shadow|alt-screen|attached-window|wedged|real-agent|busy-shell>" >&2
    exit 2
    ;;
esac

setup
echo "== $CASE  base=$BASE  build=$("$BUILD" --version)"
"case_${CASE//-/_}"
echo "== $CASE: $FAILS failed"
[ "$FAILS" -eq 0 ]
