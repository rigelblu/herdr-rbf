#!/bin/bash
# Account-preserving herdr-agent recovery, through real launcher entry points.
# All Herdr/agent processes are stand-ins in an isolated HOME and sized PTY.
# Python's standard-library pty driver supplies the terminal, not a test framework.
# Usage: RBF_TEST_ROOT=<scratch> bash rbf/scripts/herdr-agent-restore.test.sh <case>
# Cases: profile-pair reattach unset-explicit legacy-invalid unavailable-override
#        parallel-atomic write-failure compatibility privacy continuity live-auth-status
set -Eeuo pipefail
CASE=${1:-profile-pair}
REPO=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
ROOT=${RBF_TEST_ROOT:-${EXTERNAL_DRIVE:+$EXTERNAL_DRIVE/tmp/hrdr-29-tests}}
[[ -n $ROOT ]] || { echo 'set RBF_TEST_ROOT or EXTERNAL_DRIVE' >&2; exit 64; }
if [[ $ROOT == /Volumes/* ]]; then
  volume=/Volumes/$(printf '%s' "${ROOT#/Volumes/}" | cut -d/ -f1)
  mount | grep -Fq " on $volume (" || { echo 'test volume is not mounted' >&2; exit 1; }
fi
mkdir -p "$ROOT"
BASE=$(mktemp -d "$ROOT/restore-$CASE.XXXXXX")
report_error() {
  local result=$?
  trap - ERR
  printf 'FAIL %s: command exited %s\nfixture: %s\n' "$CASE" "$result" "$BASE" >&2
  [[ ! -f "$BASE/last.out" ]] || head -c 8192 "$BASE/last.out" >&2
  exit "$result"
}
trap report_error ERR
chmod 700 "$BASE"
APP=$BASE/app
STATE=$BASE/state
DB=$BASE/db.json
ID_A=11111111-1111-4111-8111-111111111111
ID_B=22222222-2222-4222-8222-222222222222
SURFACE_A=AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA
SURFACE_B=BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB
SURFACE=$SURFACE_A
PROFILE_A=$BASE/profile-a
PROFILE_B=$BASE/profile-b
mkdir -p "$APP/bin" "$APP/share/herdr-agent/bin" "$BASE/bin" "$BASE/home/.claude" "$BASE/project/.jj" "$BASE/tmp" "$STATE" "$PROFILE_A" "$PROFILE_B"
SOURCE=${HERDR_AGENT_UNDER_TEST:-$REPO/rbf/src/herdr-agent/bin/herdr-agent}
/bin/cp "$SOURCE" "$APP/bin/herdr-agent"
chmod 755 "$APP/bin/herdr-agent"
for agent in claude codex pi agy; do ln -s ../../../bin/herdr-agent "$APP/share/herdr-agent/bin/$agent"; done
JQ=$(command -v jq)
PYTHON=$(command -v python3)
ln -s "$JQ" "$BASE/bin/jq"
printf '{"counter":0,"panes":[],"race":false}\n' > "$DB"
: > "$BASE/calls.jsonl"
: > "$BASE/attaches.jsonl"

cat > "$BASE/tty-driver.py" <<'PY'
import errno, fcntl, os, pty, select, signal, struct, sys, termios, time
pid, fd = pty.fork()
if pid == 0:
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    os.execvpe(sys.argv[1], sys.argv[1:], os.environ)
deadline = time.monotonic() + 60
status = None
while True:
    if time.monotonic() > deadline:
        os.kill(pid, signal.SIGKILL)
        os.waitpid(pid, 0)
        sys.exit(124)
    if select.select([fd], [], [], .05)[0]:
        try:
            data = os.read(fd, 65536)
        except OSError as e:
            if e.errno == errno.EIO:
                break
            raise
        if not data:
            break
        sys.stdout.buffer.write(data)
        sys.stdout.buffer.flush()
    waited, result = os.waitpid(pid, os.WNOHANG)
    if waited:
        status = result
        # The PTY can still contain output after child exit.
        while select.select([fd], [], [], .05)[0]:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            sys.stdout.buffer.write(data)
        break
if status is None:
    _, status = os.waitpid(pid, 0)
os.close(fd)
sys.exit(os.waitstatus_to_exitcode(status))
PY

cat > "$BASE/bin/herdr" <<'SH'
#!/bin/bash
set -euo pipefail
lock() { until mkdir "$FAKE_DB.lock" 2>/dev/null; do sleep .01; done; }
unlock() { rmdir "$FAKE_DB.lock"; }
update() { jq "$@" "$FAKE_DB" > "$FAKE_DB.tmp"; /bin/mv -f "$FAKE_DB.tmp" "$FAKE_DB"; }
if [[ ${1:-} == --remote ]]; then
  jq -cn --args '$ARGS.positional' -- "$@" >> "$FAKE_BASE/remotes.jsonl"; exit
fi
if [[ ${1:-} == session && ${2:-} == list ]]; then
  case ${FAKE_SESSION_FAILURE:-} in
    exit) exit 75 ;; malformed) echo '{'; exit ;; empty) exit 0 ;;
    multiple) printf '{"sessions":[]}\n{"sessions":[]}\n'; exit ;;
  esac
  printf '{"sessions":[{"name":"fixture","running":true}]}\n'; exit
fi
[[ ${1:-} == --session ]] || exit 71
shift 2
case "$1 ${2:-}" in
  'workspace list') printf '{"result":{"workspaces":[{"label":"project","workspace_id":"w1"}]}}\n' ;;
  'pane list')
    case ${FAKE_PANE_FAILURE:-} in
      exit) exit 75 ;; malformed) echo '{'; exit ;; empty) exit 0 ;;
      multiple) printf '{"result":{"panes":[]}}\n{"result":{"panes":[]}}\n'; exit ;;
    esac
    snapshot=$(cat "$FAKE_DB")
    if jq -e '.race' <<< "$snapshot" >/dev/null; then
      lock; update '.race=false | .panes[0].terminal_id="term_replacement"'; unlock
    fi
    jq '{result:{panes:.panes}}' <<< "$snapshot"
    ;;
  'agent list') jq '{result:{agents:[.panes[] | select(.agent_session.value != "")]}}' "$FAKE_DB" ;;
  'tab create'|'workspace create')
    launch=
    while (($#)); do
      [[ $1 != HERDR_AGENT_LAUNCH=* ]] || launch=${1#HERDR_AGENT_LAUNCH=}
      shift
    done
    [[ -n $launch && $launch == "$TMPDIR"/* ]] || exit 72
    lock
    n=$(jq '.counter+1' "$FAKE_DB")
    pane=w1:p$n terminal=term_fixture$n
    update --arg p "$pane" --arg t "$terminal" --arg a "${FAKE_AGENT_KIND:-claude}" --argjson n "$n" \
      '.counter=$n | .panes += [{pane_id:$p,terminal_id:$t,agent:$a,agent_session:{agent:$a,value:""}}]'
    unlock
    HERDR_ENV=1 HERDR_PANE_ID="$pane" HERDR_SESSION=fixture HERDR_SOCKET_PATH="$FAKE_BASE/socket" \
      /bin/zsh -f "$launch" > "$FAKE_BASE/child-$n.out" 2>&1
    jq -cn --arg p "$pane" --arg t "$terminal" '{result:{root_pane:{pane_id:$p,terminal_id:$t},workspace:{workspace_id:"w1"},tab:{tab_id:"w1:t1"}}}'
    ;;
  'tab rename'|'pane close') printf '{"result":{}}\n' ;;
  *) printf 'unexpected fake API: %s\n' "$*" >&2; exit 73 ;;
esac
SH

cat > "$BASE/real-agent" <<'SH'
#!/bin/bash
set -euo pipefail
isset=false; [[ ! ${CLAUDE_CONFIG_DIR+x} ]] || isset=true
jq -cn --arg profile "${CLAUDE_CONFIG_DIR-}" --argjson set "$isset" \
  --arg kind "${FAKE_AGENT_KIND:-claude}" --args '{config:$profile,config_set:$set,kind:$kind,argv:$ARGS.positional}' -- "$@" >> "$FAKE_BASE/calls.jsonl"
id=
args=("$@")
for ((i=0;i<${#args[@]};i++)); do
  case ${args[i]} in --resume|--session-id|--session|--conversation) id=${args[i+1]:-} ;; esac
done
if [[ -n $id && -n ${HERDR_PANE_ID:-} ]]; then
  until mkdir "$FAKE_DB.lock" 2>/dev/null; do sleep .01; done
  jq --arg p "$HERDR_PANE_ID" --arg id "$id" '.panes |= map(if .pane_id==$p then .agent_session.value=$id else . end)' \
    "$FAKE_DB" > "$FAKE_DB.tmp"
  /bin/mv -f "$FAKE_DB.tmp" "$FAKE_DB"
  rmdir "$FAKE_DB.lock"
fi
if [[ ${HERDR_TEST_NATIVE_OBSERVER:-} == 1 ]]; then
  [[ ${args[0]:-} == --resume && -n ${args[1]:-} && ${#args[@]} == 2 ]] || exit 74
  "$REAL_CLAUDE_BIN" auth status --json > "$FAKE_BASE/native-observed.json"
fi
SH

cat > "$BASE/attach-observer" <<'SH'
#!/bin/bash
set -eu
jq -cn --args '$ARGS.positional' -- "$@" >> "$FAKE_BASE/attaches.jsonl"
SH
cat > "$BASE/bin/claude" <<'SH'
#!/bin/bash
if [[ -f "$FAKE_BASE/late-handoff" ]]; then
  jq '.panes=[{pane_id:"w9:p9",terminal_id:"term_late_handoff",agent:"claude",agent_session:{value:"11111111-1111-4111-8111-111111111111"}}]' "$FAKE_DB" > "$FAKE_DB.edit"
  /bin/mv -f "$FAKE_DB.edit" "$FAKE_DB"
fi
if [[ -n ${HERDR_TEST_CLAUDE_WRAPPER:-} ]]; then
  exec "$HERDR_TEST_CLAUDE_WRAPPER" "$@"
fi
exec "$FAKE_APP/share/herdr-agent/bin/claude" "$@"
SH
for agent in codex pi agy; do
  printf '#!/bin/bash\nexport FAKE_AGENT_KIND=%s\nexec "$FAKE_APP/share/herdr-agent/bin/%s" "$@"\n' "$agent" "$agent" > "$BASE/bin/$agent"
done
chmod 755 "$BASE/bin/"* "$BASE/real-agent" "$BASE/attach-observer"

ENV_BASE=("HOME=$BASE/home" "PATH=$BASE/bin:/usr/bin:/bin:/usr/sbin:/sbin" "TMPDIR=$BASE/tmp"
  "XDG_CONFIG_HOME=$BASE/config" "XDG_STATE_HOME=$BASE/xdg-state" "XDG_DATA_HOME=$BASE/data" "XDG_CACHE_HOME=$BASE/cache"
  "HERDR_AGENT=on" "HERDR_AGENT_SESSION=fixture" "HERDR_AGENT_STATE_DIR=$STATE"
  "HERDR_AGENT_CHECK_AGENT=$BASE/real-agent" "HERDR_AGENT_ATTACH=$BASE/attach-observer"
  "CMUX_WORKSPACE_ID=CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"
  "FAKE_BASE=$BASE" "FAKE_DB=$DB" "FAKE_APP=$APP" "FAKE_AGENT_KIND=claude")
EXTRA=()
run() {
  local config=$1; shift
  local envs=("${ENV_BASE[@]}" "CMUX_SURFACE_ID=$SURFACE")
  [[ ! ${EXTRA[*]-} ]] || envs+=("${EXTRA[@]}")
  [[ $config == unset ]] || envs+=("CLAUDE_CONFIG_DIR=$config")
  (trap - ERR; cd "$BASE/project" && /usr/bin/env -i "${envs[@]}" "$PYTHON" "$BASE/tty-driver.py" "$@") > "$BASE/last.out" 2>&1
}
launch() { run "$1" "$APP/share/herdr-agent/bin/claude" --session-id "${2:-$ID_A}"; }
restore() { run "$1" "$APP/bin/herdr-agent" attach --restore; }
clear_panes() { jq '.panes=[]' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"; }
calls() { wc -l < "$BASE/calls.jsonl" | tr -d ' '; }
attaches() { wc -l < "$BASE/attaches.jsonl" | tr -d ' '; }
fail() { printf 'FAIL %s: %s\nfixture: %s\n' "$CASE" "$*" "$BASE" >&2; head -c 8192 "$BASE/last.out" >&2; exit 1; }
check() { "$@" || fail "assertion: $*"; }
last_profile() {
  jq -se --arg p "$1" '.[-1].config_set and .[-1].config==$p' "$BASE/calls.jsonl" >/dev/null || fail 'wrong profile selected'
}
refused() {
  local config=$1 phrase=$2 before before_attaches; before=$(calls); before_attaches=$(attaches)
  local rc=0; restore "$config" || rc=$?
  [[ $rc == 1 ]] || fail "expected exit1, got $rc"
  [[ $(calls) == "$before" && $(attaches) == "$before_attaches" ]] || fail 'refusal launched or attached an agent'
  grep -Fq "$phrase" "$BASE/last.out" || fail "missing diagnostic: $phrase"
}
legacy_note() {
  mkdir -p "$STATE/tabs"
  printf 'fixture\tw1:p1\t%s\t%s\n' "${1:-claude}" "$ID_A" > "$STATE/tabs/$SURFACE"
}

case "$CASE" in
  profile-pair)
    launch "$PROFILE_A" "$ID_A"
    SURFACE=$SURFACE_B; launch "$PROFILE_B" "$ID_B"
    clear_panes
    SURFACE=$SURFACE_A; restore "$PROFILE_B"; last_profile "$PROFILE_A"
    jq -se --arg id "$ID_A" '.[-1].argv==["--resume",$id]' "$BASE/calls.jsonl" >/dev/null || fail 'resume ID/argv changed'
    SURFACE=$SURFACE_B; restore "$PROFILE_A"; last_profile "$PROFILE_B"
    ;;
  reattach)
    launch "$PROFILE_A"
    if [[ -d $STATE/claude-launch ]]; then
      /bin/cp "$STATE/claude-launch/"*.json "$BASE/original-binding"
    fi
    before=$(calls)
    SURFACE=$SURFACE_B
    run "$PROFILE_B" "$APP/bin/herdr-agent" attach fixture w1:p1
    [[ $(calls) == "$before" ]] || fail 'reattach restarted agent'
    run "$PROFILE_B" "$APP/share/herdr-agent/bin/claude" --resume "$ID_A"
    [[ $(calls) == "$before" ]] || fail 'takeover restarted agent'
    if [[ -f $BASE/original-binding ]]; then
      cmp -s "$STATE/claude-launch/"*.json "$BASE/original-binding" || fail 'reattach changed original binding'
    fi
    clear_panes; restore "$PROFILE_B"; last_profile "$PROFILE_A"
    ;;
  unset-explicit)
    launch unset; clear_panes; restore "$PROFILE_B"
    jq -se '.[-1].config_set==false' "$BASE/calls.jsonl" >/dev/null || fail 'unset launch acquired a profile'
    clear_panes
    SURFACE=$SURFACE_B; launch "$BASE/home/.claude" "$ID_B"
    clear_panes; restore unset; last_profile "$BASE/home/.claude"
    odd="$BASE/profile space"$'\t'"quote'\"\$(oops)"$'\n'
    mkdir -p "$odd"; clear_panes; launch "$odd"; clear_panes; restore "$PROFILE_B"; last_profile "$odd"
    ;;
  legacy-invalid)
    launch "$PROFILE_A"; legacy_note
    before=$(calls); restore "$PROFILE_B"; [[ $(calls) == "$before" ]] || fail 'living legacy pane restarted'
    legacy_note; clear_panes; refused "$PROFILE_B" 'original account profile is unknown'
    for data in '{' '{"version":999}' '[]' '{"version":1,"agent":"claude"}'; do
      printf '%s\n' "$data" > "$STATE/tabs/$SURFACE"
      refused "$PROFILE_B" 'saved record is invalid or unsupported'
    done
    jq -cn '{version:1,session:"fixture",pane:"w1:p1",terminal_id:"term_fixture1",agent:"claude",id:"",claude_config:{kind:"unknown",reason:"unrecorded"}}' > "$STATE/tabs/$SURFACE"
    refused "$PROFILE_B" "can't restore this tab: original account profile is unknown"
    ;;
  unavailable-override)
    launch "$PROFILE_A"; clear_panes; rmdir "$PROFILE_A"
    refused "$PROFILE_B" 'saved account profile is unavailable'
    mkdir -p "$PROFILE_A"
    for key in ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN; do
      EXTRA=("$key=credential-sentinel-never-store")
      refused "$PROFILE_B" 'an authentication override is set'
    done
    EXTRA=(); clear_panes
    launch relative-profile; clear_panes; refused "$PROFILE_B" 'original account profile is unknown'
    clear_panes; launch ''; clear_panes; refused "$PROFILE_B" 'original account profile is unknown'
    ;;
  parallel-atomic)
    (SURFACE=$SURFACE_A; launch "$PROFILE_A" "$ID_A") & a=$!
    (SURFACE=$SURFACE_B; launch "$PROFILE_B" "$ID_B") & b=$!
    wait "$a"; wait "$b"
    clear_panes
    SURFACE=$SURFACE_A; restore "$PROFILE_B"; last_profile "$PROFILE_A"
    SURFACE=$SURFACE_B; restore "$PROFILE_A"; last_profile "$PROFILE_B"
    # Fail after creating a private temporary file, before publishing a new note.
    /bin/cp "$STATE/tabs/$SURFACE" "$BASE/prior-note"
    cat > "$BASE/bin/mktemp" <<'SH'
#!/bin/bash
file=$(/usr/bin/mktemp "$@") || exit
printf '{"version":' > "$file"
exit 1
SH
    chmod 755 "$BASE/bin/mktemp"
    saved_pane=$(jq -r .pane "$BASE/prior-note")
    run "$PROFILE_A" "$APP/bin/herdr-agent" attach fixture "$saved_pane"
    [[ ! -e "$STATE/tabs/$SURFACE" ]] || fail 'failed publication left a stale recovery note'
    refused "$PROFILE_A" 'this tab has no saved herdr pane' 
    /bin/rm "$BASE/bin/mktemp"
    # A torn/partial external note must never become a profile selection.
    printf '{"version":1,"session":"fixture",' > "$STATE/tabs/$SURFACE"
    refused "$PROFILE_A" 'saved record is invalid or unsupported'
    ;;
  write-failure)
    : > "$STATE/claude-launch"
    launch "$PROFILE_A"
    grep -Fq "couldn't save Claude account context" "$BASE/last.out" || fail 'save failure was hidden'
    [[ $(attaches) == 1 && $(calls) == 1 ]] || fail 'save failure lost created agent/attach'
    clear_panes; refused "$PROFILE_B" 'original account profile is unknown'
    /bin/rm "$STATE/claude-launch"
    launch "$PROFILE_A"
    clear_panes
    cat > "$BASE/bin/mktemp" <<'SH'
#!/bin/bash
case "$1" in */tabs/.claude*) exit 1 ;; esac
exec /usr/bin/mktemp "$@"
SH
    chmod 755 "$BASE/bin/mktemp"
    launch "$PROFILE_B" "$ID_B"
    grep -Fq "couldn't save Claude account context" "$BASE/last.out" || fail 'tab-note failure was hidden'
    /bin/rm "$BASE/bin/mktemp"
    clear_panes; refused "$PROFILE_B" 'this tab has no saved herdr pane'
    ;;
  compatibility)
    for kind in codex pi agy; do
      clear_panes; legacy_note "$kind"
      EXTRA=("FAKE_AGENT_KIND=$kind"); restore "$PROFILE_A"
      jq -se --arg k "$kind" '.[-1].kind==$k' "$BASE/calls.jsonl" >/dev/null || fail 'non-Claude restore changed agent'
    done
    EXTRA=()
    run "$PROFILE_A" "$APP/bin/herdr-agent" attach --remote 'example.invalid' --session 'remote-fixture'
    restore "$PROFILE_B"
    jq -se 'length==2 and .[0]==.[1] and .[0]==["--remote","example.invalid","--session","remote-fixture"]' "$BASE/remotes.jsonl" >/dev/null || fail 'remote restore changed arguments'
    # The original parser must not interpret a compact JSON note as a Claude TSV command.
    clear_panes; launch "$PROFILE_A"; clear_panes
    if [[ -n ${HERDR_TEST_OLD_LAUNCHER:-} ]]; then
      /bin/cp "$APP/bin/herdr-agent" "$BASE/new-launcher"
      /bin/cp "$HERDR_TEST_OLD_LAUNCHER" "$APP/bin/herdr-agent"
      before=$(calls); rc=0; restore "$PROFILE_B" || rc=$?
      [[ $rc != 0 && $(calls) == "$before" ]] || fail 'old parser resumed a new Claude note'
      /bin/cp "$BASE/new-launcher" "$APP/bin/herdr-agent"
    fi
    ;;
  privacy)
    EXTRA=('ANTHROPIC_API_KEY=credential-sentinel-never-store')
    launch "$PROFILE_A"; clear_panes; EXTRA=()
    refused "$PROFILE_B" 'original account profile is unknown'
    if grep -R -Fq credential-sentinel-never-store "$STATE"; then fail 'credential leaked into persisted state'; fi
    if grep -Fq credential-sentinel-never-store "$BASE/last.out"; then fail 'credential leaked into diagnostic'; fi
    [[ $(/usr/bin/stat -f %Lp "$STATE/claude-launch") == 700 ]] || fail 'binding directory is not private'
    for file in "$STATE/claude-launch/"*.json "$STATE/tabs/$SURFACE"; do
      [[ $(/usr/bin/stat -f %Lp "$file") == 600 ]] || fail 'new record is not private'
    done
    ;;
  continuity)
    launch "$PROFILE_A"; before=$(calls)
    for key in FAKE_SESSION_FAILURE FAKE_PANE_FAILURE; do
      for failure in exit malformed empty multiple; do
        EXTRA=("$key=$failure")
        refused "$PROFILE_B" 'its terminal identity changed'
      done
    done
    EXTRA=()
    jq '.panes[0].pane_id="w2:p1"' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    restore "$PROFILE_B"
    jq -se '.[-1][2]=="w2:p1"' "$BASE/attaches.jsonl" >/dev/null || fail 'did not follow terminal across layout move'
    [[ $(calls) == "$before" ]] || fail 'move restarted agent'
    jq '.panes[0].agent=null | .panes[0].agent_session.agent="claude"' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    restore "$PROFILE_B"
    jq -e --arg p "$PROFILE_A" '.agent=="claude" and .claude_config.value==$p' "$STATE/tabs/$SURFACE" >/dev/null || fail 'undetected live attach lost Claude profile'
    jq '.panes[0].terminal_id="term_handoff"' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    refused "$PROFILE_B" 'its terminal identity changed'
    # Reuse the saved location with a different terminal and conversation.
    jq --arg id "$ID_B" '.panes[0].agent_session.value=$id' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    refused "$PROFILE_B" 'its terminal identity changed'
    jq '.panes[0].terminal_id="term_fixture1" | .race=true' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    refused "$PROFILE_B" 'its terminal identity changed'
    clear_panes; launch "$PROFILE_A"
    jq --arg id "$ID_A" '.panes=[{pane_id:"w9:p9",terminal_id:"term_undetected",agent:null,agent_session:{agent:"claude",value:$id}}]' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    refused "$PROFILE_B" 'its terminal identity changed'
    jq '.panes=[42]' "$DB" > "$DB.edit"; /bin/mv -f "$DB.edit" "$DB"
    refused "$PROFILE_B" 'its terminal identity changed'
    clear_panes; touch "$BASE/late-handoff"
    refused "$PROFILE_B" 'its terminal identity changed'
    ;;
  live-auth-status)
    # Authentication must see the real home; only Herdr/XDG state stays isolated.
    # The optional installed cmux wrapper remains in the real execution path.
    ENV_BASE[0]="HOME=$HOME"
    ENV_BASE+=("USER=${USER:-$(id -un)}" "LOGNAME=${LOGNAME:-$(id -un)}")
    for key in REAL_CLAUDE_BIN HERDR_TEST_PROFILE_A HERDR_TEST_PROFILE_B HERDR_TEST_EXPECTED_EMAIL_A HERDR_TEST_EXPECTED_EMAIL_B; do
      [[ -n ${!key:-} ]] || { echo "missing prerequisite: $key" >&2; exit 64; }
    done
    [[ -x $REAL_CLAUDE_BIN && -d $HERDR_TEST_PROFILE_A && -d $HERDR_TEST_PROFILE_B ]] || exit 64
    [[ $HERDR_TEST_PROFILE_A != "$HERDR_TEST_PROFILE_B" && $HERDR_TEST_EXPECTED_EMAIL_A != "$HERDR_TEST_EXPECTED_EMAIL_B" ]] || exit 64
    for slot in A B; do
      profile_key=HERDR_TEST_PROFILE_$slot; email_key=HERDR_TEST_EXPECTED_EMAIL_$slot
      profile=${!profile_key}; expected=${!email_key}
      /usr/bin/env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN \
        CLAUDE_CONFIG_DIR="$profile" /usr/bin/perl -e 'alarm 30; exec @ARGV or die "exec: $!\n"' "$REAL_CLAUDE_BIN" auth status --json > "$BASE/native-baseline.json"
      jq -e --arg email "$expected" '.loggedIn==true and .email==$email and (.authMethod|type=="string")' "$BASE/native-baseline.json" >/dev/null || fail 'intended baseline identity mismatch'
      clear_panes; launch "$profile"; clear_panes
      EXTRA=("REAL_CLAUDE_BIN=$REAL_CLAUDE_BIN" 'HERDR_TEST_NATIVE_OBSERVER=1')
      if [[ -n ${HERDR_TEST_CLAUDE_WRAPPER:-} ]]; then
        [[ -x $HERDR_TEST_CLAUDE_WRAPPER ]] || exit 64
        EXTRA+=("HERDR_TEST_CLAUDE_WRAPPER=$HERDR_TEST_CLAUDE_WRAPPER"
          "CMUX_CUSTOM_CLAUDE_PATH=$APP/share/herdr-agent/bin/claude" 'CMUX_CLAUDE_HOOKS_DISABLED=1')
      fi
      caller=$HERDR_TEST_PROFILE_B; [[ $slot != B ]] || caller=$HERDR_TEST_PROFILE_A
      restore "$caller"
      jq -se '.[0].loggedIn==true and .[1].loggedIn==true and .[0].email==.[1].email and .[0].authMethod==.[1].authMethod' \
        "$BASE/native-baseline.json" "$BASE/native-observed.json" >/dev/null || fail 'native restored identity mismatch'
      EXTRA=()
    done
    ;;
  *) echo "unknown case: $CASE" >&2; exit 64 ;;
esac
printf 'PASS %s\nfixture: %s\n' "$CASE" "$BASE"
