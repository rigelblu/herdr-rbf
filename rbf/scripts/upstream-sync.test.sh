#!/bin/bash

# Isolated test harness for rbf/scripts/upstream-sync.sh
# Covers hrdr-11 Scenarios 1–6, 8–10, 11 (all 9 rows), 12, 13.
#
# Usage:
#   bash rbf/scripts/upstream-sync.test.sh [<case>]
#
# If no case is given, all cases run in order.
# Exits nonzero if any check fails.
# Prints case list on unknown case name.
#
# Scratch root from $RBF_TEST_ROOT, else $EXTERNAL_DRIVE/tmp/rbf-sync-h.
# Bash 3.2 compatible. Completely isolated from user/host git/jj configs.

set -uo pipefail

CASE="${1:-}"
ROOT="${RBF_TEST_ROOT:-${EXTERNAL_DRIVE:+$EXTERNAL_DRIVE/tmp/rbf-sync-h}}"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="$REPO/rbf/scripts/upstream-sync.sh"

PYTHON_DIR="$(dirname "$(command -v python3)")"
JJ_DIR="$(dirname "$(command -v jj 2>/dev/null || printf '/usr/bin/jj')")"
TEST_PATH="$PYTHON_DIR:$JJ_DIR:/usr/bin:/bin:/usr/sbin:/sbin"
REAL_JJ="$(command -v jj 2>/dev/null || printf '/usr/bin/jj')"
REAL_MV="$(command -v mv 2>/dev/null || printf '/bin/mv')"

FAILS=0

ALL_CASES="
scenario-1
scenario-2
scenario-3
scenario-3b-concurrent-op
scenario-3c-unknown-op
scenario-4
scenario-5
scenario-5b-no-verify-cmd
scenario-6
scenario-6b-master-moved
scenario-6c-not-integrated
scenario-6d-change-moved-off-stack
scenario-6e-verify-cmd-not-from-receipt
scenario-8
scenario-8e-upstream-branch-main
scenario-8f-origin-mode-integrate
scenario-9
scenario-9c-check-detects-stale
scenario-10
scenario-11-working-copy
scenario-11-conflicted-source
scenario-11-mid-stack-checkout
scenario-11-skip-verify
scenario-11-worktree-switch
scenario-11-already-current
scenario-11-missing-upstream-remote
scenario-11-missing-upstream-branch
scenario-11-finish-rerun
scenario-12
scenario-13
scenario-13b-dropped-validation
scenario-2b-check-master-conflicted
scenario-4c-chain-inherit-only
scenario-6f-master-moved-during-verify
scenario-6f2-upstream-moved-during-verify
scenario-6g-finish-master-conflicted
scenario-6h-finish-origin-moved-since-check
scenario-7-ledger-log
scenario-8g-finish-no-local-master
scenario-14-stage-path-contains-stage
scenario-15-stage-guards
scenario-16-integrate-twice
scenario-17-finish-nonempty-child
scenario-18-ledger-padding-alignment
scenario-19-check-plural-boundaries
scenario-20-reconcile-marks-conflicted
scenario-21-stage-dirty-master-itself
scenario-22-finish-verify-amends-master
scenario-23-finish-upstream-moved-before-verify
scenario-24-reconcile-marks-clean-once-resolved
scenario-25-jj-guard-conflicts-query-fails
"

pass() { printf 'PASS  %s\n' "$*"; }
fail() {
  printf 'FAIL  %s\n' "$*"
  FAILS=$((FAILS + 1))
}
check() {
  local label="$1"
  shift
  if "$@"; then pass "$label"; else fail "$label"; fi
}

check_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if printf '%s\n' "$haystack" | grep -Fq "$needle"; then
    pass "$label"
  else
    fail "$label (expected to find: '$needle')"
  fi
}

check_not_contains() {
  local label="$1"
  local haystack="$2"
  local needle="$3"
  if ! printf '%s\n' "$haystack" | grep -Fq "$needle"; then
    pass "$label"
  else
    fail "$label (expected NOT to find: '$needle')"
  fi
}

setup_root() {
  case "$ROOT" in
    /?*) ;;
    *)
      echo "no scratch root: set RBF_TEST_ROOT, or EXTERNAL_DRIVE (root \$EXTERNAL_DRIVE/tmp/rbf-sync-h)" >&2
      exit 1
      ;;
  esac
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
}

init_case_env() {
  local c="$1"
  BASE="$ROOT/$c"
  rm -rf "$BASE"
  mkdir -p "$BASE/home" "$BASE/state" "$BASE/run" "$BASE/work" "$BASE/bin"

  cat > "$BASE/gitconfig" <<'GITCONF'
[user]
  name = "Sync Test User"
  email = "sync-test@example.com"
[commit]
  gpgsign = false
[tag]
  gpgsign = false
[init]
  defaultBranch = master
GITCONF

  cat > "$BASE/jjconfig.toml" <<'JJCONF'
user.name = "Sync Test User"
user.email = "sync-test@example.com"
ui.color = "never"
ui.paginate = "never"
signing.behavior = "own"
signing.backend = "none"
JJCONF

  export HOME="$BASE/home"
  export XDG_CONFIG_HOME="$BASE/home/.config"
  export XDG_STATE_HOME="$BASE/state"
  export XDG_RUNTIME_DIR="$BASE/run"
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL="$BASE/gitconfig"
  export JJ_CONFIG="$BASE/jjconfig.toml"
}

run_in_env() {
  local dir="$1"
  shift
  (
    cd "$dir" && \
    env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH -u HERDR_SESSION -u HERDR_ENV \
      -u HERDR_WORKSPACE_ID -u HERDR_TAB_ID -u HERDR_PANE_ID -u ZDOTDIR \
      HOME="$BASE/home" XDG_CONFIG_HOME="$BASE/home/.config" XDG_STATE_HOME="$BASE/state" \
      XDG_RUNTIME_DIR="$BASE/run" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$BASE/gitconfig" \
      JJ_CONFIG="$BASE/jjconfig.toml" \
      PATH="$BASE/bin:$TEST_PATH" SHELL=/bin/zsh "$@"
  )
}

jj_run() {
  local dir="$1"
  shift
  run_in_env "$dir" jj "$@"
}

# `check "label" jj_run ...` (or run_in_env ... jj ...) runs the jj
# command as check()'s own "$@" — its stdout streams straight to the
# terminal, ahead of (or, with no trailing newline, glued onto) the
# PASS/FAIL line check() prints next. Route the jj call through this so
# only the exit code reaches check(), never jj's own chatter.
# shellcheck disable=SC2329 # invoked through check()'s "$@"
jj_run_quiet() {
  local dir="$1"
  shift
  run_in_env "$dir" jj "$@" >/dev/null 2>&1
}

sync_run() {
  local dir="$1"
  shift
  run_in_env "$dir" bash "$SCRIPT" "$@"
}

# Standard fixture setup:
#   upstream.git (bare)
#   origin.git (bare)
#   seed (local git clone, pushes base commit to both)
#   work (jj clone of origin, upstream added, master tracking master@origin)
setup_standard_fixture() {
  local c="$1"
  init_case_env "$c"

  local up_dir="$BASE/upstream.git"
  local orig_dir="$BASE/origin.git"
  local seed_dir="$BASE/seed"
  local work_dir="$BASE/work"

  git init --bare "$up_dir" >/dev/null 2>&1
  git init --bare "$orig_dir" >/dev/null 2>&1

  git clone "$orig_dir" "$seed_dir" >/dev/null 2>&1
  (
    cd "$seed_dir" && \
    git checkout -b master >/dev/null 2>&1 || git checkout master >/dev/null 2>&1 || true
    printf 'base line 1\nbase line 2\nbase line 3\n' > file.txt
    git add file.txt
    git commit -m "base commit" >/dev/null 2>&1
    git push origin master >/dev/null 2>&1
    git remote add upstream "$up_dir"
    git push upstream master >/dev/null 2>&1
  )

  run_in_env "$BASE" jj git clone "$orig_dir" "$work_dir" >/dev/null 2>&1
  jj_run "$work_dir" git remote add upstream "$up_dir" >/dev/null 2>&1
  jj_run "$work_dir" git fetch --remote upstream >/dev/null 2>&1
  jj_run "$work_dir" bookmark track master@origin >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Test Cases
# ---------------------------------------------------------------------------

test_scenario_1() {
  local c="scenario-1"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Add a fork commit on master
  printf 'base line 1\nfork line 2\nbase line 3\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork change 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  # Add an upstream commit
  printf 'upstream line 0\n' > "$seed/up.txt"
  (
    cd "$seed" && \
    git add up.txt && \
    git commit -m "feat: upstream change" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local initial_wc_commit initial_wc_change initial_bm
  initial_wc_commit="$(jj_run "$work" log -r @ --no-graph -T 'commit_id')"
  initial_wc_change="$(jj_run "$work" log -r @ --no-graph -T 'change_id')"
  initial_bm="$(jj_run "$work" bookmark list master)"

  # Run check with no arguments
  local out rc=0
  out="$(sync_run "$work" 2>&1)" || rc=$?

  check "scenario-1 exit code 0" [ "$rc" -eq 0 ]
  check_contains "scenario-1 check header" "$out" "herdr-rbf upstream sync — check"
  check_contains "scenario-1 fetch step" "$out" "✓ fetched upstream; master@upstream"
  check_contains "scenario-1 checked summary" "$out" "✓ checked; nothing rewritten, no bookmark moved"
  check_contains "scenario-1 next row" "$out" "next         rbf/scripts/upstream-sync.sh stage"

  # Parse receipt path from output
  local receipt_path
  receipt_path="$(printf '%s\n' "$out" | sed -n 's/^[[:space:]]*receipt[[:space:]]*//p')"
  check "scenario-1 receipt path printed" [ -n "$receipt_path" ]
  # Expand tilde if present
  case "$receipt_path" in
    "~"/*) receipt_path="$BASE/home/${receipt_path#\~/}" ;;
  esac
  check "scenario-1 receipt file exists" [ -f "$receipt_path" ]

  # The output's literal last line must be the exact stage command with this run's ID
  local run_id_1 last_line
  run_id_1="$(basename "$receipt_path" .receipt)"
  last_line="$(printf '%s\n' "$out" | sed -e '/^$/d' | tail -1)"
  check "scenario-1 output ends with exact stage command" \
    [ "$last_line" = "next         rbf/scripts/upstream-sync.sh stage $run_id_1" ]

  local pre_op post_op
  pre_op="$(grep '^pre_op=' "$receipt_path" | cut -d= -f2-)"
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-1 pre_op equals live post-fetch op" [ "$pre_op" = "$post_op" ]

  local post_wc_commit post_wc_change post_bm
  post_wc_commit="$(jj_run "$work" log -r @ --no-graph -T 'commit_id')"
  post_wc_change="$(jj_run "$work" log -r @ --no-graph -T 'change_id')"
  post_bm="$(jj_run "$work" bookmark list master)"
  check "scenario-1 working copy commit unchanged" [ "$initial_wc_commit" = "$post_wc_commit" ]
  check "scenario-1 working copy change unchanged" [ "$initial_wc_change" = "$post_wc_change" ]
  check "scenario-1 local bookmarks unchanged" [ "$initial_bm" = "$post_bm" ]

  # Only fetched remote refs and their jj operation may advance — the
  # recorded pre_op (the live post-fetch op) is itself a fetch operation,
  # not some other mutation.
  local top_op_desc
  top_op_desc="$(jj_run "$work" op log --no-graph --limit 1 -T 'description.first_line()')"
  check_contains "scenario-1 recorded operation is the fetch" "$top_op_desc" "fetch"

  # The receipt's own upstream_commit is compared against the live
  # remote-tracking ref's actual target, not just checked to be present.
  local recorded_upstream_commit live_upstream_commit
  recorded_upstream_commit="$(grep '^upstream_commit=' "$receipt_path" | cut -d= -f2-)"
  live_upstream_commit="$(jj_run "$work" log -r master@upstream --no-graph -T 'commit_id.short(8)')"
  check "scenario-1 recorded upstream_commit matches master@upstream's real target" \
    [ "$recorded_upstream_commit" = "$live_upstream_commit" ]
}

test_scenario_2() {
  local c="scenario-2"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork change\n' >> "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  local pre_stage_op pre_stage_master pre_stage_status
  pre_stage_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  pre_stage_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  pre_stage_status="$(jj_run "$work" status)"

  local stage_out rc=0
  stage_out="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc=$?

  check "scenario-2 stage exit code 0" [ "$rc" -eq 0 ]
  check_contains "scenario-2 stage header" "$stage_out" "herdr-rbf upstream sync — stage"
  check_contains "scenario-2 staged operation reported" "$stage_out" "✓ staged operation"
  check_contains "scenario-2 active op unchanged" "$stage_out" "✓ active operation and this working copy unchanged; nothing integrated"
  check_contains "scenario-2 next inspect" "$stage_out" "next         rbf/scripts/upstream-sync.sh inspect $receipt_id"

  # Active jj state check
  local active_op active_master active_status
  active_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  active_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  active_status="$(jj_run "$work" status)"
  check "scenario-2 active op unchanged in live repo" [ "$active_op" = "$pre_stage_op" ]
  check "scenario-2 live master bookmark unchanged" [ "$active_master" = "$pre_stage_master" ]
  check "scenario-2 live status unchanged" [ "$active_status" = "$pre_stage_status" ]

  # Parse staged op id from output
  local staged_op
  staged_op="$(printf '%s\n' "$stage_out" | sed -n 's/.*staged operation \([a-f0-9]*\).*/\1/p')"
  check "scenario-2 staged op parsed" [ -n "$staged_op" ]

  # At-op status and log
  local at_op_master
  at_op_master="$(jj_run "$work" --at-op "$staged_op" log -r master --no-graph -T 'commit_id.short(8)')"
  check "scenario-2 at-op master names new candidate tip" [ "$at_op_master" != "$pre_stage_master" ]

  # Receipt itself must carry both pre-op and staged-op (Design data: receipt fields)
  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-2 receipt records pre_op" grep -Fq "pre_op=$pre_stage_op" "$receipt_file"
  check "scenario-2 receipt records staged_op" grep -Fq "staged_op=$staged_op" "$receipt_file"

  # The detached operation is inspectable: --at-op status succeeds and
  # shows the candidate — not just that it succeeds, but that it names
  # the rebase, checked further down.
  local at_op_status
  at_op_status="$(run_in_env "$work" jj --at-op "$staged_op" status 2>&1)"
  check "scenario-2 at-op status is readable" [ -n "$at_op_status" ]
  check_contains "scenario-2 at-op status names the working copy" "$at_op_status" "Working copy"

  # Status is checked to actually SHOW the detached candidate's own
  # state, not merely to be non-empty text with the right label — its
  # reported working-copy change must be the SAME one --at-op log itself
  # reports for @ at that exact operation (proving --at-op status really
  # time-travelled to the candidate, not the live workspace).
  local at_op_self_change status_wc_change
  at_op_self_change="$(jj_run "$work" --at-op "$staged_op" log -r @ --no-graph -T 'change_id.short(8)')"
  status_wc_change="$(printf '%s\n' "$at_op_status" | sed -n 's/^Working copy  (@) : \([a-z0-9]*\) .*/\1/p')"
  # shellcheck disable=SC2016 # $1/$2 are the nested bash -c's own positional args
  check "scenario-2 at-op status names the same working-copy change as at-op log" \
    bash -c '[ -n "$1" ] && [ "$1" = "$2" ]' _ "$status_wc_change" "$at_op_self_change"

  # --at-op log -r master names the source change rebased directly on
  # top of upstream, not merely "a different commit".
  local at_op_master_parent
  at_op_master_parent="$(jj_run "$work" --at-op "$staged_op" log -r master --no-graph -T 'parents.map(|p| p.change_id().short(8)).join(" ")')"
  local upstream_change_at_op
  upstream_change_at_op="$(jj_run "$work" --at-op "$staged_op" log -r master@upstream --no-graph -T 'change_id.short(8)')"
  check "scenario-2 at-op master sits directly on upstream" [ "$at_op_master_parent" = "$upstream_change_at_op" ]
}

test_scenario_3() {
  local c="scenario-3"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' >> "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  # Create an unrelated operation in work repo
  jj_run "$work" describe -m "unrelated operation edit" >/dev/null 2>&1
  local unrelated_op pre_master
  unrelated_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  pre_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"

  local int_out rc=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc=$?

  check "scenario-3 integrate refused exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-3 refused message" "$int_out" "✗ the repository changed since stage; nothing integrated"
  check_contains "scenario-3 expected found ops" "$int_out" "expected operation"
  check_contains "scenario-3 observed op printed" "$int_out" "found $unrelated_op"
  check_contains "scenario-3 next check" "$int_out" "next         rbf/scripts/upstream-sync.sh check"

  # Neither operation was integrated: active op is still the unrelated one, master
  # didn't move, and the receipt is still staged-not-integrated.
  local active_op_after post_master
  active_op_after="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  post_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  check "scenario-3 active op still the unrelated one" [ "$active_op_after" = "$unrelated_op" ]
  check "scenario-3 master unchanged" [ "$pre_master" = "$post_master" ]
  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-3 receipt still staged-not-integrated" grep -Fq "phase=staged-not-integrated" "$receipt_file"
}

test_scenario_3b_stage_stale() {
  # "stage" must guard the active operation just like "integrate" does —
  # both refuse unless the live active operation still equals the
  # receipt's own pre_op. Scenario 3 only exercises integrate's copy of
  # that guard; this case exercises stage's.
  local c="scenario-3b-concurrent-op"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  # An unrelated jj operation lands between check and stage (e.g. another
  # session's edit, or a review hook running jj new).
  jj_run "$work" describe -m "unrelated operation edit" >/dev/null 2>&1
  local unrelated_op
  unrelated_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"

  local stage_out rc=0
  stage_out="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc=$?

  check "scenario-3b stage refused exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-3b refused message" "$stage_out" "✗ the repository changed since check; nothing staged"
  check_contains "scenario-3b observed op printed" "$stage_out" "found $unrelated_op"
  check_contains "scenario-3b next check" "$stage_out" "next         rbf/scripts/upstream-sync.sh check"

  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-3b receipt still checked" grep -Fq "phase=checked" "$receipt_file"
  check "scenario-3b receipt has no staged_op" grep -Fxq "staged_op=" "$receipt_file"
}

test_scenario_4() {
  local c="scenario-4"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Three fork changes, so each gets its own resolve-list line: one edits
  # an upstream file (file.txt), the second adds a fork-owned file
  # (fork_file.txt, upstream also adds it with different content), and the
  # third touches an unrelated file and adds no conflict of its own — it
  # still inherits both earlier conflicts (jj carries them forward) but
  # must not repeat their files on its own row.
  printf 'fork line 1\nbase line 2\nbase line 3\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit upstream file" >/dev/null 2>&1
  local ch1
  ch1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new -m "feat: fork add own file" >/dev/null 2>&1
  printf 'fork content\n' > "$work/fork_file.txt"
  local ch2
  ch2="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new -m "feat: fork unrelated change" >/dev/null 2>&1
  printf 'unrelated content\n' > "$work/unrelated.txt"
  local ch3
  ch3="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  # Upstream modifies file.txt (causing upstream edit conflict)
  # and upstream ALSO adds fork_file.txt with different content (causing fork-owned collision)
  (
    cd "$seed" && \
    printf 'upstream line 1\nbase line 2\nbase line 3\n' > file.txt && \
    printf 'upstream collision content\n' > fork_file.txt && \
    git add file.txt fork_file.txt && \
    git commit -m "upstream conflicting commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local stage_out
  stage_out="$(sync_run "$work" stage "$receipt_id" 2>&1)"
  # Stage's own counts line uses the raw conflicts() count (3, since
  # ch3 inherits from ch1 and ch2), not the own-conflicts-filtered count
  # integrate's resolve list uses.
  check_contains "scenario-4 stage counts line" "$stage_out" "✓ 3 changes replayed; 3 hold conflicts"

  local int_out rc=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc=$?

  check "scenario-4 integrate exit code 0" [ "$rc" -eq 0 ]
  check_contains "scenario-4 conflicts reported" "$int_out" "conflicts, markers in their files"
  # Integrate's resolve recipe rows.
  check_contains "scenario-4 for each row" "$int_out" "for each     jj new <change>"
  check_contains "scenario-4 edit row" "$int_out" "             edit the files: upstream's code, with the fork's change on top"
  check_contains "scenario-4 squash row" "$int_out" "             jj squash --from '<change>..@' --into <change>"
  check_contains "scenario-4 then row" "$int_out" "then         jj new master"
  check_contains "scenario-4 next finish row" "$int_out" "next         rbf/scripts/upstream-sync.sh finish $receipt_id"
  check_contains "scenario-4 resolve bottom-up" "$int_out" "resolve bottom-up, one change at a time"
  check_contains "scenario-4 fork-owned flag" "$int_out" "⚠ fork-owned: inspect by hand"
  # The fork-owned collision's own file must be the one flagged
  check_contains "scenario-4 fork-owned file named" "$int_out" "fork_file.txt"
  # The lower change's own line (file.txt only, no fork-owned file yet) is
  # the plain upstream-file-edit conflict and carries no class flag
  local file_txt_only_line
  file_txt_only_line="$(printf '%s\n' "$int_out" | grep -F 'file.txt' | grep -Fv 'fork_file.txt')"
  check "scenario-4 upstream edit line found" [ -n "$file_txt_only_line" ]
  check_not_contains "scenario-4 upstream edit unflagged" "$file_txt_only_line" "⚠"

  # ch3 only INHERITS both earlier
  # conflicts and adds none of its own, so it gets no row at all (not a
  # blank one) — and the count line says 2, not 3.
  check_contains "scenario-4 count line says 2 changes have own conflicts" "$int_out" "2 changes have own conflicts, markers in their files"
  # Scope to the numbered resolve rows: ch3 is also the stack's own tip,
  # so its ID legitimately appears in the unrelated "master -> ..." line.
  local resolve_rows
  resolve_rows="$(printf '%s\n' "$int_out" | grep -E '^   [0-9]+ ')"
  check_not_contains "scenario-4 ch3 has no row at all" "$resolve_rows" "$ch3"

  # Bottom-up order, and each row lists only its OWN conflicted
  # files.
  local ch1_line_no ch2_line_no
  ch1_line_no="$(printf '%s\n' "$int_out" | grep -n "$ch1" | head -1 | cut -d: -f1)"
  ch2_line_no="$(printf '%s\n' "$int_out" | grep -n "$ch2" | head -1 | cut -d: -f1)"
  check "scenario-4 rows are bottom-up (ch1 < ch2)" \
    [ "$ch1_line_no" -lt "$ch2_line_no" ]

  local ch1_line ch2_line
  ch1_line="$(printf '%s\n' "$int_out" | sed -n "${ch1_line_no}p")"
  ch2_line="$(printf '%s\n' "$int_out" | sed -n "${ch2_line_no}p")"
  check_contains "scenario-4 ch1 row names file.txt" "$ch1_line" "file.txt"
  check_not_contains "scenario-4 ch1 row omits fork_file.txt" "$ch1_line" "fork_file.txt"
  check_contains "scenario-4 ch2 row names fork_file.txt" "$ch2_line" "fork_file.txt"
  check_not_contains "scenario-4 ch2 row omits file.txt (inherited)" "$ch2_line" "file.txt,"

  local conflicts_count
  conflicts_count="$(jj_run "$work" log -r 'conflicts()' --no-graph -T '"."' | wc -c | tr -d ' ')"
  check "scenario-4 conflicts remain unresolved in jj" [ "$conflicts_count" -gt 0 ]

  # integrate's own "jj workspace update-stale" must have left this workspace
  # readable immediately, not stale — jj op integrate leaves the workspace
  # that ran it stale, and every jj command there fails until update-stale
  # catches it up.
  check "scenario-4 workspace not stale after integrate" jj_run_quiet "$work" status
}

test_scenario_5() {
  local c="scenario-5"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Clean non-conflicting change
  printf 'fork edit\n' > "$work/fork.txt"
  jj_run "$work" describe -m "feat: fork clean edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  # Checkout master
  jj_run "$work" new master >/dev/null 2>&1

  local pre_master pre_origin_master
  pre_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  pre_origin_master="$(jj_run "$work" log -r master@origin --no-graph -T 'commit_id.short(8)')"

  # Run finish with failing verify command
  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'false' 2>&1)" || rc=$?

  check "scenario-5 finish failed verify exits nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-5 verify command printed" "$finish_out" "verify         false"
  check_contains "scenario-5 verification failed message" "$finish_out" "✗ verification failed"
  check_contains "scenario-5 not verified receipt unchanged" "$finish_out" "not verified, receipt unchanged"
  check_not_contains "scenario-5 no verified local master line" "$finish_out" "✓ verified local master"
  check_contains "scenario-5 rerun instructions" "$finish_out" "next         fix it in the change that broke, then run finish again"
  check_contains "scenario-5 abandon instructions" "$finish_out" "abandon      jj op restore"

  local post_master post_origin_master
  post_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  post_origin_master="$(jj_run "$work" log -r master@origin --no-graph -T 'commit_id.short(8)')"
  check "scenario-5 master commit unchanged" [ "$pre_master" = "$post_master" ]
  check "scenario-5 master@origin unchanged" [ "$pre_origin_master" = "$post_origin_master" ]

  # Check receipt phase remained integrated-clean
  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-5 receipt phase is integrated-clean" grep -Fq "phase=integrated-clean" "$receipt_file"
}

test_scenario_5b_no_verify_cmd() {
  # Finish must refuse when no verify command is configured at all — only
  # "--skip-verify" (an unknown option) and a failing verify command are
  # covered elsewhere; this is the "no command configured" case on its own.
  local c="scenario-5b-no-verify-cmd"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork clean edit\n' > "$work/fork.txt"
  jj_run "$work" describe -m "feat: fork clean edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local pre_master
  pre_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"

  # No --verify-cmd and no UPSTREAM_SYNC_VERIFY_CMD set
  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" 2>&1)" || rc=$?

  check "scenario-5b exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-5b refusal message" "$finish_out" "✗ no verify command configured; not verified, nothing run"
  check_contains "scenario-5b hint" "$finish_out" "pass --verify-cmd <cmd> or set UPSTREAM_SYNC_VERIFY_CMD"
  check_not_contains "scenario-5b no verified local master line" "$finish_out" "✓ verified local master"

  local post_master
  post_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  check "scenario-5b master unchanged" [ "$pre_master" = "$post_master" ]

  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-5b receipt still integrated-clean" grep -Fq "phase=integrated-clean" "$receipt_file"
}

test_scenario_6() {
  local c="scenario-6"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Two fork changes
  printf 'fork edit 1\n' > "$work/fork1.txt"
  jj_run "$work" describe -m "feat: fork clean edit 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  jj_run "$work" new -m "feat: fork clean edit 2" >/dev/null 2>&1
  printf 'fork edit 2\n' > "$work/fork2.txt"
  jj_run "$work" bookmark set my-feat -r @ >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local origin_master_commit source_change_id bm_names_before
  origin_master_commit="$(jj_run "$work" log -r master@origin --no-graph -T 'commit_id.short(8)')"
  source_change_id="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  bm_names_before="$(jj_run "$work" bookmark list -T 'name ++ "\n"' | sort -u)"

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  jj_run "$work" new master >/dev/null 2>&1

  local pre_finish_master pre_finish_op
  pre_finish_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  pre_finish_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"

  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?

  check "scenario-6 finish exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-6 verification passed" "$finish_out" "✓ verification passed"
  check_contains "scenario-6 verified local master line" "$finish_out" "✓ verified local master; master@origin unchanged at $origin_master_commit"
  check_contains "scenario-6 not done row" "$finish_out" "not done     push, install, release, upstream PR"

  # The checkout-report line is checked to exist, and its claimed
  # relationship (this empty change's PARENT is master) is verified
  # independently against jj, not just trusted from the printed line.
  check_contains "scenario-6 checkout line reports empty child of master" "$finish_out" "checkout       @ is an empty child of master"
  local at_parent_change master_change_now
  at_parent_change="$(jj_run "$work" log -r '@-' --no-graph -T 'change_id.short(8)')"
  master_change_now="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  check "scenario-6 actual parent is master" [ "$at_parent_change" = "$master_change_now" ]
  check_contains "scenario-6 master bookmark line" "$finish_out" "✓ master ->"
  check_contains "scenario-6 my-feat bookmark line" "$finish_out" "✓ my-feat ->"

  # Assert the actual reported target, not just that a line exists.
  local my_feat_commit my_feat_change
  my_feat_commit="$(jj_run "$work" log -r my-feat --no-graph -T 'commit_id.short(8)')"
  my_feat_change="$(jj_run "$work" log -r my-feat --no-graph -T 'change_id.short(8)')"
  check_contains "scenario-6 my-feat reports its real new target" "$finish_out" "✓ my-feat -> $my_feat_change $my_feat_commit"

  # Finish is local-only — the operations it added gained no fetch or
  # push (only operations from before this finish call are excluded, since
  # check's own earlier fetch legitimately appears further back in the log).
  local new_op_descs
  new_op_descs="$(jj_run "$work" op log --no-graph -T 'id.short(12) ++ "\t" ++ description.first_line() ++ "\n"' | awk -v stop="$pre_finish_op" -F'\t' '$1==stop{exit} {print}')"
  check_not_contains "scenario-6 finish's own operations gained no fetch" "$new_op_descs" "fetch"
  check_not_contains "scenario-6 finish's own operations gained no push" "$new_op_descs" "push"

  local post_finish_master post_origin_master
  post_finish_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  post_origin_master="$(jj_run "$work" log -r master@origin --no-graph -T 'commit_id.short(8)')"

  check "scenario-6 master was unchanged by finish" [ "$pre_finish_master" = "$post_finish_master" ]
  check "scenario-6 master@origin unchanged" [ "$origin_master_commit" = "$post_origin_master" ]

  # master is the rebased successor of the very change check chose as source
  local post_finish_change_id
  post_finish_change_id="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  check "scenario-6 master is rebased successor of source change" [ "$post_finish_change_id" = "$source_change_id" ]

  # finish writes no bookmark: the same set of names exists before and after
  local bm_names_after
  bm_names_after="$(jj_run "$work" bookmark list -T 'name ++ "\n"' | sort -u)"
  check "scenario-6 no bookmark created or removed" [ "$bm_names_before" = "$bm_names_after" ]

  local state_dir receipt_file
  state_dir="$BASE/state/herdr-rbf-upstream-sync"
  receipt_file="$state_dir/$receipt_id.receipt"
  check "scenario-6 receipt phase is verified-local-master" grep -Fq "phase=verified-local-master" "$receipt_file"
  check "scenario-6 receipt records the verified tip" grep -Fq "verified_tip_commit=$post_finish_master" "$receipt_file"
}

test_scenario_8() {
  local c="scenario-8"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  (
    cd "$seed" && \
    printf 'upstream new content\n' > up.txt && \
    git add up.txt && \
    git commit -m "upstream new commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local state_dir="$BASE/state/herdr-rbf-upstream-sync"

  # Subcase 8a: master tracks master@upstream -> check refuses and prints fix,
  # BEFORE writing a receipt
  jj_run "$work" bookmark untrack master@origin >/dev/null 2>&1
  jj_run "$work" bookmark track master@upstream >/dev/null 2>&1

  local out8a rc8a=0
  out8a="$(sync_run "$work" 2>&1)" || rc8a=$?
  check "scenario-8a exit nonzero" [ "$rc8a" -ne 0 ]
  check_contains "scenario-8a tracks upstream refusal" "$out8a" "✗ master tracks master@upstream; nothing fetched, no receipt written"
  check_contains "scenario-8a fix once row" "$out8a" "fix once     jj bookmark untrack master@upstream"
  check "scenario-8a no receipt written" [ ! -d "$state_dir" ]

  # Subcase 8b: master tracks master@origin -> check chooses master, and
  # records its commit and change ID
  jj_run "$work" bookmark untrack master@upstream >/dev/null 2>&1
  jj_run "$work" bookmark track master@origin >/dev/null 2>&1
  local expected_master_commit expected_master_change
  expected_master_commit="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  expected_master_change="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  local out8b rc8b=0
  out8b="$(sync_run "$work" 2>&1)" || rc8b=$?
  check "scenario-8b exit 0" [ "$rc8b" -eq 0 ]
  local receipt_id_8b
  receipt_id_8b="$(printf '%s\n' "$out8b" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file_8b="$state_dir/$receipt_id_8b.receipt"
  check "scenario-8b source is master" grep -Fq "source_ref=master" "$rec_file_8b"
  check "scenario-8b records source commit" grep -Fq "source_commit=$expected_master_commit" "$rec_file_8b"
  check "scenario-8b records source change id" grep -Fq "source_change_id=$expected_master_change" "$rec_file_8b"

  # Moving @ elsewhere changes none of these — also holds in the
  # tracks-master@origin state (8b), not only the no-local-master one (8d).
  jj_run "$work" new "root()" -m "unrelated commit" >/dev/null 2>&1
  local out8b2 rc8b2=0
  out8b2="$(sync_run "$work" 2>&1)" || rc8b2=$?
  check "scenario-8b (@ moved) exit 0" [ "$rc8b2" -eq 0 ]
  local receipt_id_8b2
  receipt_id_8b2="$(printf '%s\n' "$out8b2" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file_8b2="$state_dir/$receipt_id_8b2.receipt"
  check "scenario-8b (@ moved) source still master" grep -Fq "source_ref=master" "$rec_file_8b2"
  check "scenario-8b (@ moved) records same source commit" grep -Fq "source_commit=$expected_master_commit" "$rec_file_8b2"
  jj_run "$work" new master >/dev/null 2>&1

  # Subcase 8c: no local master -> check chooses master@origin, and records
  # its commit and change ID (not master's, which no longer resolves)
  jj_run "$work" bookmark delete master >/dev/null 2>&1
  local expected_origin_commit expected_origin_change
  expected_origin_commit="$(jj_run "$work" log -r master@origin --no-graph -T 'commit_id.short(8)')"
  expected_origin_change="$(jj_run "$work" log -r master@origin --no-graph -T 'change_id.short(8)')"
  local out8c rc8c=0
  out8c="$(sync_run "$work" 2>&1)" || rc8c=$?
  check "scenario-8c exit 0" [ "$rc8c" -eq 0 ]
  local receipt_id_8c
  receipt_id_8c="$(printf '%s\n' "$out8c" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file_8c="$state_dir/$receipt_id_8c.receipt"
  check "scenario-8c source is master@origin" grep -Fq "source_ref=master@origin" "$rec_file_8c"
  check "scenario-8c records source commit" grep -Fq "source_commit=$expected_origin_commit" "$rec_file_8c"
  check "scenario-8c records source change id" grep -Fq "source_change_id=$expected_origin_change" "$rec_file_8c"

  # Subcase 8d: moving @ elsewhere changes nothing
  jj_run "$work" new "root()" -m "unrelated commit" >/dev/null 2>&1
  local out8d rc8d=0
  out8d="$(sync_run "$work" 2>&1)" || rc8d=$?
  check "scenario-8d exit 0" [ "$rc8d" -eq 0 ]
  local receipt_id_8d
  receipt_id_8d="$(printf '%s\n' "$out8d" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file_8d="$state_dir/$receipt_id_8d.receipt"
  check "scenario-8d source still master@origin" grep -Fq "source_ref=master@origin" "$rec_file_8d"
  check "scenario-8d records source commit" grep -Fq "source_commit=$expected_origin_commit" "$rec_file_8d"
}

test_scenario_9() {
  local c="scenario-9"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream commit" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"

  # Subcase 9a: Fault injection: mv fails during atomic replace in stage
  cat > "$BASE/bin/mv" <<SHIM
#!/bin/sh
if [ "\${FAIL_MV:-}" = "1" ]; then
  echo "mv simulated failure" >&2
  exit 1
fi
exec "$REAL_MV" "\$@"
SHIM
  chmod +x "$BASE/bin/mv"

  local stage_fail_out rc_fail=0
  stage_fail_out="$(FAIL_MV=1 sync_run "$work" stage "$receipt_id" 2>&1)" || rc_fail=$?
  check "scenario-9a stage with failing mv exits nonzero" [ "$rc_fail" -ne 0 ]
  check_contains "scenario-9a reports the atomic-write failure" "$stage_fail_out" "Error: failed to write receipt atomically"
  # Receipt must still be in 'checked' phase, not half-written — check
  # the whole receipt survived intact, not just its phase= line.
  check "scenario-9a receipt preserved last complete phase" grep -Fq "phase=checked" "$rec_file"
  check "scenario-9a receipt still has no staged_op (untouched)" grep -Fxq "staged_op=" "$rec_file"
  check "scenario-9a receipt still records source_change_id" grep -Fq "source_change_id=" "$rec_file"
  check "scenario-9a receipt still records the change map" grep -Fq "change=" "$rec_file"
  check "scenario-9a no leftover .tmp receipt file" \
    [ "$(find "$(dirname "$rec_file")" -name '*.tmp.*' | wc -l | tr -d ' ')" = 0 ]

  # The next command (inspect) must read that preserved phase and refuse
  # cleanly, not crash on a half-written receipt.
  local insp_after_fail_out rc_insp=0
  insp_after_fail_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc_insp=$?
  check "scenario-9a inspect on unstaged receipt refuses" [ "$rc_insp" -ne 0 ]
  check_contains "scenario-9a inspect reports no staged operation" "$insp_after_fail_out" "staged operation not found"

  # Now let stage succeed
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  check "scenario-9a receipt updated to staged" grep -Fq "phase=staged-not-integrated" "$rec_file"

  # Subcase 9b: Simulate kill right after jj op integrate succeeds, before update-stale and receipt rename
  cat > "$BASE/bin/jj" <<JJSHIM
#!/bin/sh
if [ "\${INTERRUPT_INTEGRATE:-}" = "1" ] && [ "\$#" -ge 2 ] && [ "\$1" = "op" ] && [ "\$2" = "integrate" ]; then
  "$REAL_JJ" "\$@"
  rc=\$?
  kill -9 \$PPID 2>/dev/null || true
  exit 137
fi
exec "$REAL_JJ" "\$@"
JJSHIM
  chmod +x "$BASE/bin/jj"

  local int_kill_out rc_kill=0
  int_kill_out="$(INTERRUPT_INTEGRATE=1 sync_run "$work" integrate "$receipt_id" 2>&1)" || rc_kill=$?
  check "scenario-9b integrate killed exits nonzero" [ "$rc_kill" -ne 0 ]
  check_contains "scenario-9b kill happens mid-integrate" "$int_kill_out" "⋯ integrating operation"

  # The receipt is never half-written: right after the kill it must still
  # read as the last complete phase (staged-not-integrated), even though
  # jj op integrate itself already succeeded live.
  check "scenario-9b receipt still last-complete-phase right after kill" \
    grep -Fq "phase=staged-not-integrated" "$rec_file"

  # Remove the shim and run inspect first: it's not `finish`, so this also
  # proves EVERY command that takes a receipt reconciles, not just finish.
  # The next command reports the receipt's reconciled phase, not the
  # stale staged-not-integrated one.
  rm -f "$BASE/bin/jj"
  local insp_reconcile_out rc_insp2=0
  insp_reconcile_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc_insp2=$?
  check "scenario-9b inspect (as the next command) reconciles and succeeds" [ "$rc_insp2" -eq 0 ]
  check_contains "scenario-9b inspect reports the reconciled phase" "$insp_reconcile_out" "(integrated-clean)"
  check "scenario-9b receipt reconciled by inspect, not just finish" \
    grep -Fq "phase=integrated-clean" "$rec_file"
  # Inspect's own "next" line on a reconciled integrated-clean
  # receipt points at finish, not back at integrate.
  check_contains "scenario-9b inspect next line points at finish" \
    "$insp_reconcile_out" "next         rbf/scripts/upstream-sync.sh finish $receipt_id"

  jj_run "$work" new master >/dev/null 2>&1

  local finish_rec_out rc_rec=0
  finish_rec_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc_rec=$?
  check "scenario-9b finish reconciles and passes" [ "$rc_rec" -eq 0 ]
  check_contains "scenario-9b finish verified output" "$finish_rec_out" "✓ verified local master"
  check "scenario-9b receipt reached verified phase" grep -Fq "phase=verified-local-master" "$rec_file"
}

test_scenario_10() {
  local c="scenario-10"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/file1.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  local f1
  f1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work" new -m "feat: fork 2" >/dev/null 2>&1
  printf 'fork 2\n' > "$work/file2.txt"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  jj_run "$work" new master -m "" >/dev/null 2>&1

  printf 'upstream change\n' > "$seed/up.txt"
  (
    cd "$seed" && \
    git add up.txt && \
    git commit -m "upstream change" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local state_dir_10="$BASE/state/herdr-rbf-upstream-sync"

  # 1. Non-empty revision on top of master. Reads here use
  # --ignore-working-copy so probing doesn't itself snapshot extra.txt into
  # a new operation ahead of stage (which would trip stage's active-op
  # guard instead of the guard revset this case targets).
  printf 'edit on top\n' > "$work/extra.txt"
  local extra_change op_count_before op_count_after
  extra_change="$(jj_run "$work" --ignore-working-copy log -r @ --no-graph -T 'change_id.short(8)')"
  op_count_before="$(jj_run "$work" --ignore-working-copy op log --no-graph -T '"."' | wc -c | tr -d ' ')"

  local stage_out1 rc1=0
  stage_out1="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc1=$?
  check "scenario-10 non-empty edit on top stops stage" [ "$rc1" -ne 0 ]
  check_contains "scenario-10 names revision" "$stage_out1" "1 change outside the fork stack would be rewritten; nothing staged"
  check_contains "scenario-10 names the exact change id" "$stage_out1" "$extra_change"
  check_contains "scenario-10 next row check" "$stage_out1" "rbf/scripts/upstream-sync.sh check"

  # This row's own change (jj new master -m "")
  # is undescribed. IFS=$'\t' read collapses an empty middle field, so
  # before the fix the parent's change ID landed in the description slot
  # and the row read "(outside the stack)" instead of "on top of <id>".
  # Assert the exact row: description AND placement, not just the ID.
  local source_change_id_10
  source_change_id_10="$(grep '^source_change_id=' "$state_dir_10/$receipt_id.receipt" | cut -d= -f2-)"
  check_contains "scenario-10 undescribed row exact text" "$stage_out1" \
    "  $extra_change  (no description set)  (on top of $source_change_id_10)"

  op_count_after="$(jj_run "$work" --ignore-working-copy op log --no-graph -T '"."' | wc -c | tr -d ' ')"
  check "scenario-10 refusal creates no operation" [ "$op_count_before" = "$op_count_after" ]
  check "scenario-10 receipt still checked after refusal" grep -Fq "phase=checked" "$state_dir_10/$receipt_id.receipt"

  # 2. Abandon edit, leave only empty working copy on top of master -> stage proceeds
  rm -f "$work/extra.txt"

  local stage_out2 rc2=0
  stage_out2="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-10 empty working copy allows stage" [ "$rc2" -eq 0 ]
  check_contains "scenario-10 stage succeeds" "$stage_out2" "✓ staged operation"

  # The staged result must carry that empty change on the new (rebased) tip
  local staged_op_2
  staged_op_2="$(printf '%s\n' "$stage_out2" | sed -n 's/.*staged operation \([a-f0-9]*\).*/\1/p')"
  check "scenario-10 staged candidate carries the empty change" \
    jj_run_quiet "$work" --at-op "$staged_op_2" log -r "$extra_change" --no-graph -T 'change_id'

  # Its PARENT is the new (rebased) tip, not just "it exists
  # somewhere in the staged op" — the source_change_id is stable across
  # rebase, so this proves it's parented on the rebased stack, not still
  # dangling off the pre-rebase position.
  local source_change_id_10
  source_change_id_10="$(grep '^source_change_id=' "$state_dir_10/$receipt_id.receipt" | cut -d= -f2-)"
  local extra_parent_change
  extra_parent_change="$(jj_run "$work" --at-op "$staged_op_2" log -r "${extra_change}-" --no-graph -T 'change_id.short(8)')"
  check "scenario-10 empty change's parent is the new tip" \
    [ "$extra_parent_change" = "$source_change_id_10" ]

  # Reset receipt for side-commit test
  # 3. Non-empty side commit off mid-stack change f1
  jj_run "$work" new -r "$f1" -m "wip: try a sidebar tweak" >/dev/null 2>&1
  printf 'sidebar tweak\n' > "$work/sidebar.txt"
  local side_change
  side_change="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  local op_count_before3 op_count_after3
  op_count_before3="$(jj_run "$work" op log --no-graph -T '"."' | wc -c | tr -d ' ')"

  local stage_out3 rc3=0
  stage_out3="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc3=$?
  check "scenario-10 side commit off mid-stack stops stage" [ "$rc3" -ne 0 ]
  check_contains "scenario-10 side commit message" "$stage_out3" "1 change outside the fork stack would be rewritten; nothing staged"
  check_contains "scenario-10 side commit names itself" "$stage_out3" "$side_change"
  check_contains "scenario-10 side commit off parent" "$stage_out3" "a side commit off $f1"

  op_count_after3="$(jj_run "$work" op log --no-graph -T '"."' | wc -c | tr -d ' ')"
  check "scenario-10 side-commit refusal creates no operation" [ "$op_count_before3" = "$op_count_after3" ]
  check "scenario-10 receipt still checked after side-commit refusal" \
    grep -Fq "phase=checked" "$state_dir_10/$receipt_id.receipt"
}

test_scenario_11_working_copy() {
  local c="scenario-11-working-copy"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/file1.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  jj_run "$work" new master -m "" >/dev/null 2>&1

  printf 'upstream\n' > "$seed/up.txt"
  (
    cd "$seed" && \
    git add up.txt && \
    git commit -m "upstream" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  # Make working copy dirty
  printf 'dirty content\n' > "$work/dirty.txt"
  local dirty_change
  dirty_change="$(jj_run "$work" --ignore-working-copy log -r @ --no-graph -T 'change_id.short(8)')"

  local pre_op
  pre_op="$(jj_run "$work" --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)')"
  local stage_out rc=0
  stage_out="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc=$?
  check "scenario-11-working-copy exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-working-copy ✗ message" "$stage_out" "outside the fork stack would be rewritten; nothing staged"
  # Same message as Scenario 10, naming the specific revision
  check_contains "scenario-11-working-copy names the revision" "$stage_out" "$dirty_change"
  # The exact row, undescribed change and correct placement —
  # not just that the change ID appears somewhere in the output.
  local source_change_id_11wc
  source_change_id_11wc="$(grep '^source_change_id=' "$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt" | cut -d= -f2-)"
  check_contains "scenario-11-working-copy undescribed row exact text" "$stage_out" \
    "  $dirty_change  (no description set)  (on top of $source_change_id_11wc)"
  local post_op
  post_op="$(jj_run "$work" --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-working-copy op log gained nothing" [ "$pre_op" = "$post_op" ]
}

test_scenario_11_conflicted_source() {
  local c="scenario-11-conflicted-source"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Create a conflict already in the source stack
  printf 'fork 1\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  # Upstream commit
  printf 'upstream 1\n' > "$seed/file.txt"
  (
    cd "$seed" && \
    git commit -am "upstream 1" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  # Fetch upstream and rebase to intentionally conflict the source range
  jj_run "$work" git fetch --remote upstream >/dev/null 2>&1
  jj_run "$work" rebase -b master -d master@upstream >/dev/null 2>&1
  local conflicted_change
  conflicted_change="$(jj_run "$work" --ignore-working-copy log -r master --no-graph -T 'change_id.short(8)')"

  local pre_op
  pre_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  local out rc=0
  out="$(sync_run "$work" 2>&1)" || rc=$?
  check "scenario-11-conflicted-source exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-conflicted-source refusal" "$out" "✗ conflicts in the source range"
  check_contains "scenario-11-conflicted-source names the conflicted change" "$out" "$conflicted_change"
  local post_op
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-conflicted-source op log gained nothing" [ "$pre_op" = "$post_op" ]
}

test_scenario_11_mid_stack_checkout() {
  local c="scenario-11-mid-stack-checkout"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/file1.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  local f1
  f1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work" new -m "feat: fork 2" >/dev/null 2>&1
  printf 'fork 2\n' > "$work/file2.txt"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream\n' > "$seed/up.txt"
  (
    cd "$seed" && \
    git add up.txt && \
    git commit -m "upstream" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  # Checkout mid-stack commit f1
  jj_run "$work" edit "$f1" >/dev/null 2>&1

  local pre_op
  pre_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-11-mid-stack-checkout exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-mid-stack-checkout refusal" "$finish_out" "✗ @ is not master"
  check_contains "scenario-11-mid-stack-checkout next row" "$finish_out" "jj new master"
  local post_op
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-mid-stack-checkout op log gained nothing" [ "$pre_op" = "$post_op" ]
}

test_scenario_11_skip_verify() {
  local c="scenario-11-skip-verify"
  setup_standard_fixture "$c"
  local work="$BASE/work"

  local pre_op
  pre_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  local finish_out rc=0
  finish_out="$(sync_run "$work" finish 20260922-1412 --skip-verify 2>&1)" || rc=$?
  check "scenario-11-skip-verify exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-skip-verify unknown option" "$finish_out" "unknown option"
  check_contains "scenario-11-skip-verify usage printed" "$finish_out" "usage: rbf/scripts/upstream-sync.sh"
  local post_op
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-skip-verify op log gained nothing" [ "$pre_op" = "$post_op" ]
}

test_scenario_11_worktree_switch() {
  local c="scenario-11-worktree-switch"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream\n' > "$seed/up.txt"
  (
    cd "$seed" && \
    git add up.txt && \
    git commit -m "upstream" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  # Create task worktree
  local task_work="$BASE/task-worktree"
  jj_run "$work" workspace add "$task_work" -r master >/dev/null 2>&1

  # Run check in main worktree
  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  # Run stage in task worktree
  local stage_out rc=0
  stage_out="$(sync_run "$task_work" stage "$receipt_id" 2>&1)" || rc=$?
  check "scenario-11-worktree-switch stage in task worktree exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-11-worktree-switch staged op reported" "$stage_out" "✓ staged operation"
}

test_scenario_11_already_current() {
  local c="scenario-11-already-current"
  setup_standard_fixture "$c"
  local work="$BASE/work"

  # Upstream is already ancestor of fork (no new commits in upstream)
  local out rc=0
  out="$(sync_run "$work" 2>&1)" || rc=$?
  check "scenario-11-already-current exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-11-already-current message" "$out" "✓ upstream is already in the fork; nothing to stage, no receipt written"
  check "scenario-11-already-current no receipt written" [ ! -d "$BASE/state/herdr-rbf-upstream-sync" ]
  # The header always opens check, before
  # fetching, even for already-current; no trailing blank line after the
  # message (the whole output is exactly 4 lines: header, fetching,
  # fetched, message).
  check_contains "scenario-11-already-current has header" "$out" "herdr-rbf upstream sync — check"
  check "scenario-11-already-current header is the first line" \
    [ "$(printf '%s\n' "$out" | head -1)" = "herdr-rbf upstream sync — check" ]
  check "scenario-11-already-current exactly 4 lines, no trailing blank" \
    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 4 ]
  check "scenario-11-already-current message is the last line" \
    [ "$(printf '%s\n' "$out" | tail -1)" = "✓ upstream is already in the fork; nothing to stage, no receipt written" ]
}

test_scenario_11_missing_upstream_remote() {
  local c="scenario-11-missing-upstream-remote"
  setup_standard_fixture "$c"
  local work="$BASE/work"

  # Remove upstream remote
  jj_run "$work" git remote remove upstream >/dev/null 2>&1

  local pre_op
  pre_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  local out rc=0
  out="$(sync_run "$work" 2>&1)" || rc=$?
  check "scenario-11-missing-upstream-remote exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-missing-upstream-remote ✗ line" "$out" "✗ no upstream remote; nothing fetched, no receipt written"
  check_contains "scenario-11-missing-upstream-remote fix line" "$out" "git remote add upstream"
  check "scenario-11-missing-upstream-remote no receipt written" [ ! -d "$BASE/state/herdr-rbf-upstream-sync" ]
  local post_op
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-missing-upstream-remote op log gained nothing" [ "$pre_op" = "$post_op" ]
}

test_scenario_11_missing_upstream_branch() {
  local c="scenario-11-missing-upstream-branch"
  setup_standard_fixture "$c"
  local work="$BASE/work"

  local pre_op
  pre_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  # Override UPSTREAM_BRANCH to a nonexistent branch
  local out rc=0
  out="$(UPSTREAM_BRANCH="nonexistent" sync_run "$work" 2>&1)" || rc=$?
  local post_op
  post_op="$(jj_run "$work" op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-11-missing-upstream-branch op log gained nothing" [ "$pre_op" = "$post_op" ]
  check "scenario-11-missing-upstream-branch exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-11-missing-upstream-branch ✗ line" "$out" "✗ nonexistent@upstream not found"
  check_contains "scenario-11-missing-upstream-branch hint" "$out" "UPSTREAM_BRANCH"
  check "scenario-11-missing-upstream-branch no receipt written" [ ! -d "$BASE/state/herdr-rbf-upstream-sync" ]
}

test_scenario_11_finish_rerun() {
  local c="scenario-11-finish-rerun"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/upstream.txt"
  (
    cd "$seed" && \
    git add upstream.txt && \
    git commit -m "upstream" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  jj_run "$work" new master >/dev/null 2>&1

  # First run fails verify
  sync_run "$work" finish "$receipt_id" --verify-cmd 'false' >/dev/null 2>&1 || true

  # Second run passes verify
  local rerun_out rc=0
  rerun_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-11-finish-rerun exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-11-finish-rerun verified line" "$rerun_out" "✓ verified local master"
  check_contains "scenario-11-finish-rerun not done line" "$rerun_out" "not done     push, install, release, upstream PR"

  # "the receipt records both attempts": the run log carries both the
  # failed and the successful finish outcomes for this run ID.
  local log_file
  log_file="$BASE/home/Library/Logs/herdr-rbf-upstream-sync.log"
  check_contains "scenario-11-finish-rerun log records failed attempt" \
    "$(cat "$log_file" 2>/dev/null)" "finish failed"
  check_contains "scenario-11-finish-rerun log records verified attempt" \
    "$(cat "$log_file" 2>/dev/null)" "finish verified run_id=$receipt_id"
}

test_scenario_12() {
  local c="scenario-12"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Base file setup with multi-line files
  cat << 'FILE' > "$seed/a.txt"
line 1
line 2
line 3
FILE
  cat << 'FILE' > "$seed/b.txt"
line 1
line 2
line 3
FILE
  cat << 'FILE' > "$seed/c.txt"
line 1
line 2
line 3
FILE
  (
    cd "$seed" && \
    git add a.txt b.txt c.txt && \
    git commit -m "add test files" >/dev/null 2>&1 && \
    git push origin master >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" bookmark set master -r master@origin >/dev/null 2>&1
  jj_run "$work" new master -m "feat: lower change (#tag1)" >/dev/null 2>&1

  # Change 1 (lower): conflicts on a.txt
  cat << 'FILE' > "$work/a.txt"
line 1
fork line 2
line 3
FILE
  local ch1
  ch1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  # Change 2 (middle): touches only b.txt (no conflicts with upstream)
  jj_run "$work" new -m "feat: middle change (#tag1)" >/dev/null 2>&1
  printf 'middle b content\n' > "$work/b.txt"
  local ch2
  ch2="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  # Change 3 (top): conflicts on c.txt. Shares ch1's #tag1 subject tag on
  # purpose: two changes sharing a tag must stay separate ledger rows,
  # not merge into one just because subject tags aren't trusted for grouping.
  jj_run "$work" new -m "feat: top change (#tag1)" >/dev/null 2>&1
  cat << 'FILE' > "$work/c.txt"
line 1
fork line 2
line 3
FILE
  local ch3
  ch3="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  # Upstream modifies a.txt and c.txt, but does NOT modify b.txt
  (
    cd "$seed" && \
    printf 'upstream line 2\n' > a.txt && \
    printf 'upstream line 2\n' > c.txt && \
    git commit -am "upstream changes to a and c" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local insp_out rc=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc=$?

  check "scenario-12 inspect exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-12 ledger header" "$insp_out" "conflicts each change adds"
  check_contains "scenario-12 ch1 listed in ledger" "$insp_out" "$ch1"
  check_contains "scenario-12 ch3 listed in ledger" "$insp_out" "$ch3"
  # ch2 touched b.txt, inherited a.txt conflict from ch1, but adds 0 own conflicts!
  check_not_contains "scenario-12 ch2 not in ledger" "$insp_out" "$ch2"

  # The ledger lists bottom-up, matching integrate's
  # own bottom-up resolve list: the lower change (ch1) appears before the
  # higher one (ch3).
  local ch1_line_no ch3_line_no
  ch1_line_no="$(printf '%s\n' "$insp_out" | grep -n "$ch1" | head -1 | cut -d: -f1)"
  ch3_line_no="$(printf '%s\n' "$insp_out" | grep -n "$ch3" | head -1 | cut -d: -f1)"
  check "scenario-12 ledger lists bottom-up (ch1 before ch3)" \
    [ "$ch1_line_no" -lt "$ch3_line_no" ]

  # Assert the exact subject, path, and region count for each
  # row — not just that the change ID appears somewhere. A wrong printed
  # count or corrupted path/count pair must fail here even though the
  # change ID and header text are unaffected.
  check_contains "scenario-12 ch1 exact subject" "$insp_out" "feat: lower change (#tag1)"
  check_contains "scenario-12 ch1 exact region count" "$insp_out" "1 region"
  check_contains "scenario-12 ch1 exact path/count pair" "$insp_out" "a.txt 1"
  check_contains "scenario-12 ch3 exact subject" "$insp_out" "feat: top change (#tag1)"
  check_contains "scenario-12 ch3 exact path/count pair" "$insp_out" "c.txt 1"
  # ch1 and ch3 share the #tag1 subject tag but must stay separate rows,
  # each with its own file (S12) — not merged, not double-counted.
  check_not_contains "scenario-12 ch1 and ch3 not merged into one row" "$insp_out" "a.txt 1 · c.txt 1"
  check_contains "scenario-12 classes line exact totals" "$insp_out" "classes    upstream-file edit 2 · fork-owned collision 0 · unknown 0"

  # Verify ch1 and ch2 (sharing #tag1) stay separate rows in change map walk
  check_contains "scenario-12 carried preview" "$insp_out" "fork changes"

  # Scenario 12's "How to verify" also requires: (a) a case where parent and
  # child conflict at DIFFERENT regions of the SAME file, where the child's
  # row counts its own region; and (b) a case where the child edits INSIDE
  # a region it inherited, where the child's row counts none. Built as a
  # fully separate fixture so it can't inherit the a.txt/c.txt conflicts
  # already live in the first fixture's history.
  local c2="scenario-12-regions"
  setup_standard_fixture "$c2"
  local work2="$BASE/work"
  local seed2="$BASE/seed"

  cat << 'FILE' > "$seed2/d.txt"
d1
d2
d3
FILE
  (
    cd "$seed2" && \
    git add d.txt && \
    git commit -m "add d.txt" >/dev/null 2>&1 && \
    git push origin master >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )
  jj_run "$work2" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work2" bookmark set master -r master@origin >/dev/null 2>&1

  jj_run "$work2" new master -m "feat: region parent (edits d.txt line 1)" >/dev/null 2>&1
  printf 'chp d1\nd2\nd3\n' > "$work2/d.txt"
  local chp
  chp="$(jj_run "$work2" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work2" new -m "feat: region child same region (edits d.txt line 1 again)" >/dev/null 2>&1
  printf 'chc d1\nd2\nd3\n' > "$work2/d.txt"
  local chc
  chc="$(jj_run "$work2" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work2" new -m "feat: region child different region (edits d.txt line 3)" >/dev/null 2>&1
  printf 'chc d1\nd2\nchc2 d3\n' > "$work2/d.txt"
  local chc2
  chc2="$(jj_run "$work2" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work2" bookmark set master -r @ >/dev/null 2>&1

  # Upstream edits both line 1 and line 3 of d.txt, so both fork edits conflict
  (
    cd "$seed2" && \
    printf 'up d1\nd2\nup d3\n' > d.txt && \
    git commit -am "upstream edits both regions of d.txt" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out2
  check_out2="$(sync_run "$work2" 2>&1)"
  local receipt_id2
  receipt_id2="$(printf '%s\n' "$check_out2" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work2" stage "$receipt_id2" >/dev/null 2>&1

  local insp_out2 rc2=0
  insp_out2="$(sync_run "$work2" inspect "$receipt_id2" 2>&1)" || rc2=$?
  check "scenario-12 region inspect exit 0" [ "$rc2" -eq 0 ]

  # chp introduces the first (and only, at that point) region on d.txt
  check_contains "scenario-12 region parent listed" "$insp_out2" "$chp"
  # chc only re-edits the SAME region it inherited from chp: own count is 0
  check_not_contains "scenario-12 region child (same region) not listed" "$insp_out2" "$chc"
  # chc2 adds a genuinely NEW region (line 3) on top of an already-conflicted
  # file: its own count must still be counted, not suppressed
  check_contains "scenario-12 region child (new region) listed" "$insp_out2" "$chc2"
  # Assert chc2's own row actually reports 1 region on d.txt, not
  # just that its change ID appears somewhere in the output.
  local chc2_line_no
  chc2_line_no="$(printf '%s\n' "$insp_out2" | grep -n "$chc2" | head -1 | cut -d: -f1)"
  local chc2_region_line
  chc2_region_line="$(printf '%s\n' "$insp_out2" | sed -n "$((chc2_line_no + 1))p")"
  check_contains "scenario-12 chc2's own count is d.txt 1" "$chc2_region_line" "d.txt 1"
}

test_scenario_13() {
  local c="scenario-13"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Fork change 1: upstream will also make this exact diff (making it empty
  # after rebase). Its subject is deliberately longer than 61 chars, to
  # exercise the empty-change row's exact cut-with-ellipsis length.
  printf 'shared fix\n' > "$work/shared.txt"
  jj_run "$work" describe -m "feat: shared fix that is deliberately long enough to need truncation for this test" >/dev/null 2>&1
  local ch1
  ch1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  # Fork change 2: to be abandoned (missing)
  jj_run "$work" new -m "feat: to abandon" >/dev/null 2>&1
  printf 'abandon content\n' > "$work/abandon.txt"
  local ch2
  ch2="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  # Fork change 3: normal carried change
  jj_run "$work" new -m "feat: carried fix" >/dev/null 2>&1
  printf 'carried content\n' > "$work/carried.txt"
  local ch3
  ch3="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  # Upstream makes the same change as ch1
  (
    cd "$seed" && \
    printf 'shared fix\n' > shared.txt && \
    git add shared.txt && \
    git commit -m "upstream makes shared fix" >/dev/null 2>&1 && \
    git push upstream master >/dev/null 2>&1
  )

  local check_out
  check_out="$(sync_run "$work" 2>&1)"
  local receipt_id
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  # inspect previews the same carried/empty/missing split before anyone
  # resolves or drops anything: ch1 is already empty, ch2 and ch3 carried.
  local insp_preview_out rc_i=0
  insp_preview_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc_i=$?
  check "scenario-13 inspect preview exit 0" [ "$rc_i" -eq 0 ]
  check_contains "scenario-13 inspect preview counts" "$insp_preview_out" "fork changes 2 carried · 1 empty · 0 missing"

  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  # Now abandon ch2
  jj_run "$work" abandon "$ch2" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  # Run finish without --dropped: must refuse with missing change
  local finish_missing_out rc_m=0
  finish_missing_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc_m=$?
  check "scenario-13 missing change exits nonzero" [ "$rc_m" -ne 0 ]
  check_contains "scenario-13 missing refusal line" "$finish_missing_out" "✗ 1 fork change is missing; not verified, nothing run"
  check_contains "scenario-13 missing names ch2" "$finish_missing_out" "$ch2"
  check_contains "scenario-13 mentions empty ch1, no drop yet" "$finish_missing_out" "empty: $ch1; dropped: none"

  # Now run finish WITH --dropped <ch2>: must succeed, showing carried, empty ch1, dropped ch2
  local finish_dropped_out rc_d=0
  finish_dropped_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' --dropped "$ch2" 2>&1)" || rc_d=$?
  check "scenario-13 finish with --dropped exits 0" [ "$rc_d" -eq 0 ]
  check_contains "scenario-13 carried line" "$finish_dropped_out" "carried 1 of 3 fork changes; empty: $ch1; missing: none; dropped: $ch2"
  check_contains "scenario-13 warning for empty change" "$finish_dropped_out" "⚠ 1 fork change is now empty; upstream already has it, or its side was lost"
  check_contains "scenario-13 verified local master" "$finish_dropped_out" "✓ verified local master"
  check_contains "scenario-13 check summary row" "$finish_dropped_out" "check        each empty change: jj diff -r <change> against upstream's"

  # The empty-change row cuts its subject at 61 chars + "…", so the row
  # fits 80 columns.
  check_contains "scenario-13 empty-change row exact cut" "$finish_dropped_out" \
    "$ch1  feat: shared fix that is deliberately long enough to need tru…"
}

# ---------------------------------------------------------------------------
# Cases beyond the 13 numbered scenarios and Scenario 11's rows: edge cases
# and hardening for check/stage/inspect/integrate/finish's own guards.
# ---------------------------------------------------------------------------

test_scenario_6b_master_moved() {
  # Finish refuses when master is no longer the recorded
  # stack tip (matched by change ID), even though live conflicts()/checkout
  # checks alone would not catch it.
  local c="scenario-6b-master-moved"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream edit\n' > "$seed/upstream.txt"
  ( cd "$seed" && git add upstream.txt && git commit -m "upstream" >/dev/null 2>&1 && git push upstream master >/dev/null 2>&1 )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  # Force master onto upstream's own tip: it's no longer the recorded stack tip.
  jj_run "$work" bookmark set master -r master@upstream --allow-backwards >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6b exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6b refusal message" "$finish_out" "✗ master is not the recorded stack tip; not verified, nothing run"
  check_not_contains "scenario-6b no verified line" "$finish_out" "✓ verified local master"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-6b receipt not verified" \
    bash -c '! grep -Fq "phase=verified-local-master" "$1"' _ "$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
}

test_scenario_6c_not_integrated() {
  # Finish refuses a receipt that was never staged or
  # integrated (phase stays "checked"), instead of verifying whatever the
  # untouched, un-rebased tree happens to look like.
  local c="scenario-6c-not-integrated"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream edit\n' > "$seed/upstream.txt"
  ( cd "$seed" && git add upstream.txt && git commit -m "upstream" >/dev/null 2>&1 && git push upstream master >/dev/null 2>&1 )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  jj_run "$work" new master >/dev/null 2>&1

  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6c exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6c refusal names phase" "$finish_out" "✗ receipt is not yet integrated (phase: checked); not verified, nothing run"
  check_contains "scenario-6c next row points to stage" "$finish_out" "next         rbf/scripts/upstream-sync.sh stage $receipt_id"
  check_not_contains "scenario-6c no verified line" "$finish_out" "✓ verified local master"
}

test_scenario_6d_change_moved_off_stack() {
  # A change map walk that isn't scoped to the recorded
  # range would find a change that still "exists" anywhere in the repo and
  # call it carried, even after it's been rebased outside the stack.
  local c="scenario-6d-change-moved-off-stack"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/f1.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  local ch1
  ch1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new -m "feat: fork 2" >/dev/null 2>&1
  printf 'fork 2\n' > "$work/f2.txt"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream edit\n' > "$seed/up.txt"
  ( cd "$seed" && git add up.txt && git commit -m "upstream" >/dev/null 2>&1 && git push upstream master >/dev/null 2>&1 )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  # Move ch1 off the stack entirely: reparented directly onto upstream,
  # outside master's own ancestry.
  jj_run "$work" rebase -r "$ch1" -d master@upstream >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local finish_out rc=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6d exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6d missing refusal names ch1" "$finish_out" "$ch1"
  check_contains "scenario-6d missing refusal line" "$finish_out" "fork change is missing; not verified, nothing run"
}

test_scenario_6e_verify_cmd_not_from_receipt() {
  # The receipt records the verify command that ran, but finish never
  # reads one back from it.
  local c="scenario-6e-verify-cmd-not-from-receipt"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream edit\n' > "$seed/upstream.txt"
  ( cd "$seed" && git add upstream.txt && git commit -m "upstream" >/dev/null 2>&1 && git push upstream master >/dev/null 2>&1 )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  printf 'verify_cmd=exit 99\n' >> "$rec_file"

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6e finish uses the CLI command, not the receipt's" [ "$rc" -eq 0 ]
  check_contains "scenario-6e verified" "$out" "✓ verified local master"
  check "scenario-6e receipt records what actually ran" grep -Fxq "verify_cmd=true" "$rec_file"
}

test_scenario_3c_unknown_staged_op() {
  # Inspect and integrate refuse an unknown staged operation (checking
  # that jj --at-op <op> actually resolves), not just an empty one.
  local c="scenario-3c-unknown-op"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream edit\n' > "$seed/upstream.txt"
  ( cd "$seed" && git add upstream.txt && git commit -m "upstream" >/dev/null 2>&1 && git push upstream master >/dev/null 2>&1 )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  sed -i '' 's/^staged_op=.*/staged_op=00000000000000000000000000000000/' "$rec_file"

  local insp_out rc1=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc1=$?
  check "scenario-3c inspect refuses unknown op" [ "$rc1" -ne 0 ]
  check_contains "scenario-3c inspect message" "$insp_out" "staged operation not found"

  local pre_master
  pre_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  local int_out rc2=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-3c integrate refuses unknown op" [ "$rc2" -ne 0 ]
  check_contains "scenario-3c integrate message" "$int_out" "staged operation not found"
  local post_master
  post_master="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  check "scenario-3c integrate changed nothing" [ "$pre_master" = "$post_master" ]
}

test_scenario_9c_check_detects_stale() {
  # Check must detect a stale workspace and say so, never misdiagnose
  # it as some other guard's failure (e.g. "no upstream remote").
  local c="scenario-9c-check-detects-stale"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork 1\n' > "$work/f1.txt"
  jj_run "$work" describe -m "feat: fork 1" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm upstream && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  cat > "$BASE/bin/jj" <<JJSHIM
#!/bin/sh
if [ "\${INTERRUPT_INTEGRATE:-}" = "1" ] && [ "\$#" -ge 2 ] && [ "\$1" = "op" ] && [ "\$2" = "integrate" ]; then
  "$REAL_JJ" "\$@"; kill -9 \$PPID 2>/dev/null || true; exit 137
fi
exec "$REAL_JJ" "\$@"
JJSHIM
  chmod +x "$BASE/bin/jj"
  INTERRUPT_INTEGRATE=1 sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1 || true
  rm -f "$BASE/bin/jj"

  local out rc=0
  out="$(sync_run "$work" check 2>&1)" || rc=$?
  check "scenario-9c check refuses on stale workspace" [ "$rc" -ne 0 ]
  check_contains "scenario-9c check names staleness" "$out" "✗ this workspace is stale; nothing done"
  check_not_contains "scenario-9c check doesn't misdiagnose as no-remote" "$out" "no upstream remote"
  check_contains "scenario-9c check's next row" "$out" "next         jj workspace update-stale"
}

test_scenario_8e_upstream_branch_main() {
  # The conflict/range revsets are built from the receipt's own
  # upstream_commit and source_change_id, never hard-coded
  # master@upstream..master; verified with UPSTREAM_BRANCH=main.
  local c="scenario-8e-upstream-branch-main"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  ( cd "$seed" && git push -q upstream master:main )
  # setup_standard_fixture's own base push already left a
  # "master" branch on upstream (the pre-fork base commit) — a
  # hard-coded master@upstream..master revset would silently overlap
  # with that stale ref and still happen to catch this fixture's
  # conflict, masking a bug that only uses a hard-coded revset. Deleting
  # it makes master@upstream genuinely NOT EXIST, so only the receipt's
  # own dynamic upstream_commit (never a literal "master@upstream") can
  # find anything here.
  git -C "$BASE/upstream.git" update-ref -d refs/heads/master
  printf 'fork line\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: conflicting fork edit" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  ( cd "$seed" && printf 'upstream line\n' > file.txt && git commit -qam "upstream edit" && git push -q upstream master:main )

  local check_out receipt_id
  check_out="$(UPSTREAM_BRANCH=main sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  UPSTREAM_BRANCH=main sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local int_out rc=0
  int_out="$(UPSTREAM_BRANCH=main sync_run "$work" integrate "$receipt_id" 2>&1)" || rc=$?
  check "scenario-8e integrate exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-8e conflict detected under UPSTREAM_BRANCH=main" "$int_out" "1 change has own conflicts, markers in their files"

  jj_run "$work" new master >/dev/null 2>&1
  local finish_out rc2=0
  finish_out="$(UPSTREAM_BRANCH=main sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc2=$?
  check "scenario-8e finish refuses the real conflict" [ "$rc2" -ne 0 ]
  check_contains "scenario-8e finish names conflicts remain" "$finish_out" "✗ conflicts remain in the fork stack"

  # Resolve the conflict and prove
  # finish actually PASSES afterward under UPSTREAM_BRANCH=main — not
  # just that it refuses before. A hard-coded master@upstream..master
  # would find nothing here (no such ref at all) and stay silent forever,
  # never allowing a real pass to prove the dynamic range was used.
  local top_change
  top_change="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new "$top_change" >/dev/null 2>&1
  printf 'resolved\n' > "$work/file.txt"
  jj_run "$work" squash --from "${top_change}..@" --into "$top_change" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local remaining_conflicts
  remaining_conflicts="$(jj_run "$work" log -r 'conflicts()' --no-graph -T '"."' | wc -c | tr -d ' ')"
  check "scenario-8e sanity: conflict genuinely resolved in jj" [ "$remaining_conflicts" -eq 0 ]

  local finish_out2 rc3=0
  finish_out2="$(UPSTREAM_BRANCH=main sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc3=$?
  check "scenario-8e finish passes once resolved" [ "$rc3" -eq 0 ]
  check_contains "scenario-8e finish verified after resolving" "$finish_out2" "✓ verified local master"
}

test_scenario_8f_origin_mode_integrate() {
  # The master@origin source mode (no local master bookmark) must
  # detect real conflicts correctly through integrate too, not silently
  # report "no conflicts" because a hard-coded master@upstream..master
  # revset can't resolve without a local master.
  local c="scenario-8f-origin-mode-integrate"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  ( cd "$seed" && printf 'fork line\n' > file.txt && git commit -qam "feat: fork edit pushed to origin" && git push -q origin master )
  ( cd "$seed" && git reset -q --hard HEAD~1 && printf 'upstream line\n' > file.txt && git commit -qam "upstream edit" && git push -q upstream master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" bookmark delete master >/dev/null 2>&1

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  check "scenario-8f source is master@origin" grep -Fq "source_ref=master@origin" "$rec_file"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local int_out rc=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc=$?
  check "scenario-8f integrate exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-8f conflict detected without local master" "$int_out" "1 change has own conflicts, markers in their files"
}

test_scenario_13b_dropped_validation() {
  # --dropped is recorded atomically and only after every other guard
  # passes; an ID that's still carried, or that isn't a fork change in
  # this receipt, is refused; a rerun without the flag honors a
  # previously-recorded drop.
  local c="scenario-13b-dropped-validation"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  # Three changes: bottom (stays carried), middle (to be dropped — NOT
  # master's own tip, so abandoning it doesn't touch master itself), top
  # (stays carried, master points here).
  printf 'fork bottom\n' > "$work/fbottom.txt"
  jj_run "$work" describe -m "feat: fork bottom" >/dev/null 2>&1
  jj_run "$work" new -m "feat: fork middle" >/dev/null 2>&1
  printf 'fork middle\n' > "$work/fmiddle.txt"
  local ch_middle
  ch_middle="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new -m "feat: fork top" >/dev/null 2>&1
  printf 'fork top\n' > "$work/ftop.txt"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm upstream && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  local ch1="$ch_middle"

  local out1 rc1=0
  out1="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' --dropped "$ch1" 2>&1)" || rc1=$?
  check "scenario-13b refuses a still-carried drop" [ "$rc1" -ne 0 ]
  check_contains "scenario-13b still-carried message" "$out1" "is still carried; it can't be dropped"
  # shellcheck disable=SC2016 # $1/$2 are the nested bash -c's own positional args
  check "scenario-13b nothing recorded on refusal" \
    bash -c '! grep -Fq "dropped=$1" "$2"' _ "$ch1" "$rec_file"

  local out2 rc2=0
  out2="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' --dropped zzzzzzzz 2>&1)" || rc2=$?
  check "scenario-13b refuses an unknown id" [ "$rc2" -ne 0 ]
  check_contains "scenario-13b unknown id message" "$out2" "is not a fork change in this receipt"

  jj_run "$work" abandon "$ch1" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1
  local rc3=0
  sync_run "$work" finish "$receipt_id" --verify-cmd 'true' --dropped "$ch1" >/dev/null 2>&1 || rc3=$?
  check "scenario-13b drop of a genuinely missing change succeeds" [ "$rc3" -eq 0 ]
  check "scenario-13b receipt records the drop" grep -Fq "dropped=$ch1" "$rec_file"
  # The drop line carries the finish run's own timestamp,
  # not just the ID.
  # shellcheck disable=SC2016 # $1/$2 are the nested bash -c's own positional args
  check "scenario-13b drop line carries a timestamp" \
    bash -c 'grep -qE "^dropped=$1 [0-9]{4}-" "$2"' _ "$ch1" "$rec_file"

  local out4 rc4=0
  out4="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc4=$?
  check "scenario-13b rerun without --dropped still honors the drop" [ "$rc4" -eq 0 ]
  check_contains "scenario-13b rerun verified" "$out4" "✓ verified local master"
}

# ---------------------------------------------------------------------------
# More edge cases and hardening, covering the guards check/stage/inspect/
# integrate/finish rely on for correctness under races and unusual state.
# ---------------------------------------------------------------------------

test_scenario_2b_check_master_conflicted() {
  # Check must refuse a CONFLICTED local master
  # rather than silently falling back to master@origin — that fallback
  # would drop the unpushed fork change master (conflicted) still names.
  local c="scenario-2b-check-master-conflicted"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: local fork change, unpushed" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )
  # Someone else pushes to origin (the fork's own remote) independently of
  # this workspace's local, unpushed master.
  ( cd "$seed" && printf 'o\n' > o.txt && git add -A && git commit -qm "someone pushed to origin" && git push -q origin master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1

  local out rc=0
  out="$(sync_run "$work" 2>&1)" || rc=$?
  check "scenario-2b exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-2b refusal" "$out" "✗ master is conflicted; nothing fetched, no receipt written"
  check_contains "scenario-2b fix line" "$out" "fix once     jj bookmark set master -r <rev>"
  check "scenario-2b no receipt written" [ ! -d "$BASE/state/herdr-rbf-upstream-sync" ]
}

test_scenario_4c_chain_inherit_only() {
  # Coordinator's proof: a mid-stack change conflicts, and two changes
  # ABOVE it only inherit that conflict (jj carries a conflicted tree to
  # every descendant) — the resolve list must show exactly ONE row, and
  # the count line must say 1, not 3.
  local c="scenario-4c-chain-inherit-only"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  jj_run "$work" describe -m "feat: bottom, no conflict of its own" >/dev/null 2>&1
  printf 'own bottom\n' > "$work/bottom.txt"

  jj_run "$work" new -m "feat: mid, conflicts with upstream" >/dev/null 2>&1
  printf 'fork line\n' > "$work/file.txt"
  local mid
  mid="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work" new -m "feat: upper 1, only inherits" >/dev/null 2>&1
  printf 'own upper1\n' > "$work/upper1.txt"
  local upper1
  upper1="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"

  jj_run "$work" new -m "feat: upper 2, only inherits" >/dev/null 2>&1
  printf 'own upper2\n' > "$work/upper2.txt"
  local upper2
  upper2="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  printf 'upstream line\n' > "$seed/file.txt"
  ( cd "$seed" && git add -A && git commit -qm "upstream edits file.txt" && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local int_out rc=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc=$?
  check "scenario-4c integrate exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-4c count line says 1" "$int_out" "1 change has own conflicts, markers in their files"

  # Scope the row check to the numbered resolve rows themselves: upper2 is
  # also the stack's own tip, so its change ID legitimately appears in the
  # unrelated "master -> ..." line above — only the numbered rows matter
  # here.
  local resolve_rows
  resolve_rows="$(printf '%s\n' "$int_out" | grep -E '^   [0-9]+ ')"
  check_contains "scenario-4c mid row present" "$resolve_rows" "$mid"
  check_not_contains "scenario-4c upper1 has no row" "$resolve_rows" "$upper1"
  check_not_contains "scenario-4c upper2 has no row" "$resolve_rows" "$upper2"

  local row_count
  row_count="$(printf '%s\n' "$resolve_rows" | grep -c '')"
  check "scenario-4c exactly one resolve row" [ "$row_count" -eq 1 ]

  local conflicts_count
  conflicts_count="$(jj_run "$work" log -r 'conflicts()' --no-graph -T '"."' | wc -c | tr -d ' ')"
  check "scenario-4c all three changes are in conflicts() (jj carries it up)" [ "$conflicts_count" -eq 3 ]
}

test_scenario_6f_finish_master_moved_during_verify() {
  # The verify command runs arbitrary code and can
  # move master itself — finish must re-read master after verify and
  # refuse rather than stamp verified-local-master onto a stale candidate.
  local c="scenario-6f-master-moved-during-verify"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local before
  before="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'jj bookmark set master -r master@upstream --allow-backwards >/dev/null 2>&1' 2>&1)" || rc=$?
  check "scenario-6f exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6f refusal" "$out" "✗ master or the upstream tip moved during verification; not verified, receipt unchanged"
  check_not_contains "scenario-6f no verified line" "$out" "✓ verified local master"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-6f receipt not verified" \
    bash -c '! grep -Fq "phase=verified-local-master" "$1"' _ "$rec_file"

  local after
  after="$(jj_run "$work" log -r master --no-graph -T 'commit_id.short(8)')"
  check "scenario-6f master really did move (sanity)" [ "$before" != "$after" ]
}

test_scenario_6f2_finish_upstream_moved_during_verify() {
  # The upstream tip can also advance during the
  # verify command (a hook that fetches) — finish must catch that too.
  local c="scenario-6f2-upstream-moved-during-verify"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  # Upstream advances again, after check/stage/integrate recorded the old tip.
  printf 'y\n' > "$seed/up2.txt"
  ( cd "$seed" && git add -A && git commit -qm "upstream advances again" && git push -q upstream master )

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'jj git fetch --remote upstream >/dev/null 2>&1' 2>&1)" || rc=$?
  check "scenario-6f2 exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6f2 refusal" "$out" "✗ master or the upstream tip moved during verification; not verified, receipt unchanged"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-6f2 receipt not verified" \
    bash -c '! grep -Fq "phase=verified-local-master" "$1"' _ "$rec_file"
}

test_scenario_6g_finish_master_conflicted() {
  # Local master can itself become a CONFLICTED
  # bookmark between integrate and finish (a push to origin, then a
  # fetch, while master already moved past origin's old tip during
  # integrate). Before the fix, jj_guard's exit inside the command
  # substitution subshell never stopped the script: the error text
  # became $master_change's value and finish kept going. After the fix,
  # jj_guard's message goes to stderr and finish stops immediately.
  local c="scenario-6g-finish-master-conflicted"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  ( cd "$seed" && printf 'o\n' > o.txt && git add -A && git commit -qm "someone pushed to origin" && git push -q origin master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6g exit nonzero" [ "$rc" -ne 0 ]
  # jj_guard's own "is conflicted" branch, not its generic "jj
  # failed" fallback — the same fix once row `check` prints for the same
  # condition, plus a next.
  check_contains "scenario-6g nice conflicted-master message" "$out" "✗ master is conflicted; not verified, nothing run"
  check_contains "scenario-6g fix once row" "$out" "fix once     jj bookmark set master -r <rev>"
  check_contains "scenario-6g next row" "$out" "next         rbf/scripts/upstream-sync.sh finish $receipt_id"
  check_not_contains "scenario-6g no verified line" "$out" "✓ verified local master"
  # Before this was fixed, jj_guard's error text leaked into this exact
  # garbled line instead of stopping the script. Its absence is what
  # proves finish actually stopped there, not merely that some refusal
  # printed.
  check_not_contains "scenario-6g does not garble into the stack-tip message" "$out" "master is not the recorded stack tip"
}

test_scenario_6h_finish_origin_moved_since_check() {
  # Finish re-reads master@origin and compares it against the
  # receipt's own origin_commit, refusing if they differ — even when
  # nothing about local master itself changed. A real push+fetch race
  # here also conflicts local master (a different, already-covered path:
  # scenario-6g), so this drives the guard directly by corrupting the
  # receipt's recorded origin_commit, the same way scenario-6e drives
  # the verify-command guard by editing verify_cmd= directly.
  local c="scenario-6h-finish-origin-moved-since-check"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  # shellcheck disable=SC2016 # $1/$2 are the nested bash -c's own positional args
  bash -c 'sed -i "" "s/^origin_commit=.*/origin_commit=deadbeef/" "$1"' _ "$rec_file"

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-6h exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-6h refusal" "$out" "✗ master@origin moved since check; not verified, nothing run"
  check_contains "scenario-6h names the recorded and current values" "$out" "recorded deadbeef, now"
  check_not_contains "scenario-6h no verified line" "$out" "✓ verified local master"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-6h receipt not verified" \
    bash -c '! grep -Fq "phase=verified-local-master" "$1"' _ "$rec_file"
}

test_scenario_7_ledger_log() {
  # Inspect and integrate cap their on-screen ledger/resolve
  # rows (3 and 4), but every row (change, subject, path/count pairs,
  # total) must still be recoverable from the log.
  local c="scenario-7-ledger-log"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  local names="a b c d e"
  local n
  for n in $names; do
    printf 'seed %s\n' "$n" > "$seed/${n}.txt"
  done
  ( cd "$seed" && git add -A && git commit -qm "seed files" && git push -q origin master && git push -q upstream master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" bookmark set master -r master@origin >/dev/null 2>&1

  local first=1
  local ch change_ids=""
  for n in $names; do
    if [ "$first" -eq 1 ]; then
      jj_run "$work" new master -m "feat: edit ${n}.txt" >/dev/null 2>&1
      first=0
    else
      jj_run "$work" new -m "feat: edit ${n}.txt" >/dev/null 2>&1
    fi
    printf 'fork %s\n' "$n" > "$work/${n}.txt"
    ch="$(jj_run "$work" log -r @ --no-graph -T 'change_id.short(8)')"
    change_ids="$change_ids $ch"
  done
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  (
    cd "$seed" && \
    for n in $names; do printf 'upstream %s\n' "$n" > "${n}.txt"; done && \
    git commit -am "upstream edits all five files" >/dev/null 2>&1 && \
    git push -q upstream master
  )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local insp_out rc1=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc1=$?
  check "scenario-7 inspect exit 0" [ "$rc1" -eq 0 ]
  check_contains "scenario-7 inspect caps on screen" "$insp_out" "(2 more"

  local int_out rc2=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-7 integrate exit 0" [ "$rc2" -eq 0 ]
  check_contains "scenario-7 integrate caps on screen" "$int_out" "(1 more)"
  check_contains "scenario-7 count line says 5" "$int_out" "5 changes have own conflicts, markers in their files"

  local log_file log_content
  log_file="$BASE/home/Library/Logs/herdr-rbf-upstream-sync.log"
  log_content="$(cat "$log_file" 2>/dev/null)"

  local inspect_ledger_lines integrate_ledger_lines
  inspect_ledger_lines="$(printf '%s\n' "$log_content" | grep -c "ledger run_id=$receipt_id phase=inspect change=")"
  integrate_ledger_lines="$(printf '%s\n' "$log_content" | grep -c "ledger run_id=$receipt_id phase=integrate change=")"
  check "scenario-7 log has all 5 inspect ledger rows" [ "$inspect_ledger_lines" -eq 5 ]
  check "scenario-7 log has all 5 integrate ledger rows" [ "$integrate_ledger_lines" -eq 5 ]

  for ch in $change_ids; do
    check_contains "scenario-7 log inspect row for $ch" "$log_content" "phase=inspect change=$ch"
    check_contains "scenario-7 log integrate row for $ch" "$log_content" "phase=integrate change=$ch"
  done
}

test_scenario_8g_finish_no_local_master() {
  # In the master@origin source mode (no local master
  # bookmark existed at check time), integrate carries the rebase but
  # writes no local bookmark — finish must refuse with the exact
  # recovery, not a generic jj-doesn't-exist error.
  local c="scenario-8g-finish-no-local-master"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  ( cd "$seed" && printf 'fork line\n' > file.txt && git commit -qam "feat: fork edit pushed to origin" && git push -q origin master )
  ( cd "$seed" && git reset -q --hard HEAD~1 && printf 'upstream line\n' > file.txt && git commit -qam "upstream edit" && git push -q upstream master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" bookmark delete master >/dev/null 2>&1

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  local source_change_id
  source_change_id="$(grep '^source_change_id=' "$rec_file" | cut -d= -f2-)"

  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local int_out rc1=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc1=$?
  check "scenario-8g integrate exit 0" [ "$rc1" -eq 0 ]
  check_contains "scenario-8g says recorded tip, not master" "$int_out" "✓ integrated; recorded tip ->"
  check_not_contains "scenario-8g never claims master moved" "$int_out" "✓ integrated; master ->"

  jj_run "$work" new "heads(::${source_change_id})" >/dev/null 2>&1

  local finish_out rc2=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc2=$?
  check "scenario-8g finish exit nonzero" [ "$rc2" -ne 0 ]
  check_contains "scenario-8g refusal" "$finish_out" "✗ no local master; not verified, nothing run"
  check_contains "scenario-8g fix once line" "$finish_out" "fix once     jj bookmark set master -r $source_change_id"
  check_contains "scenario-8g next line" "$finish_out" "next         jj new master"
}

test_scenario_14_stage_path_contains_stage() {
  # The harness's receipt-ID parser must not be fooled by a
  # scratch path that itself contains the substring "stage" (this case's
  # own directory does, on purpose) — anchor to the "next ... stage <id>"
  # row, not a bare "stage" match anywhere in captured output.
  local c="scenario-14-path-contains-stage-word"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-14 parsed a real run id, not a path fragment" \
    bash -c 'case "$1" in */*) exit 1 ;; "") exit 1 ;; *) exit 0 ;; esac' _ "$receipt_id"

  local stage_out rc=0
  stage_out="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc=$?
  check "scenario-14 stage exit 0" [ "$rc" -eq 0 ]

  local insp_out rc2=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-14 inspect exit 0" [ "$rc2" -eq 0 ]

  local int_out rc3=0
  int_out="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc3=$?
  check "scenario-14 integrate exit 0" [ "$rc3" -eq 0 ]

  jj_run "$work" new master >/dev/null 2>&1
  local finish_out rc4=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc4=$?
  check "scenario-14 finish exit 0" [ "$rc4" -eq 0 ]
  check_contains "scenario-14 verified" "$finish_out" "✓ verified local master"
  # shellcheck disable=SC2016 # $1 is the nested bash -c's own positional arg
  check "scenario-14 BASE path really contains the word stage" \
    bash -c 'case "$1" in *stage*) exit 0 ;; *) exit 1 ;; esac' _ "$BASE"
}

test_scenario_15_stage_guards() {
  # Stage refuses to stage the SAME receipt twice, and also refuses an
  # OLDER receipt that shares this same
  # pre_op with one that's already staged — that would silently create a
  # second detached rewrite of identical content.
  local c="scenario-15-stage-guards"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out1 r1
  check_out1="$(sync_run "$work" 2>&1)"
  r1="$(printf '%s\n' "$check_out1" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  local check_out2 r2
  check_out2="$(sync_run "$work" 2>&1)"
  r2="$(printf '%s\n' "$check_out2" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  check "scenario-15 two checks make two distinct receipts" [ "$r1" != "$r2" ]

  local out1 rc1=0
  out1="$(sync_run "$work" stage "$r2" 2>&1)" || rc1=$?
  check "scenario-15 first stage of r2 exit 0" [ "$rc1" -eq 0 ]

  local out2 rc2=0
  out2="$(sync_run "$work" stage "$r2" 2>&1)" || rc2=$?
  check "scenario-15 staging r2 again refuses" [ "$rc2" -ne 0 ]
  check_contains "scenario-15 refusal" "$out2" "✗ already staged as operation"

  local out3 rc3=0
  out3="$(sync_run "$work" stage "$r1" 2>&1)" || rc3=$?
  check "scenario-15 staging r1 (older, same pre_op) refuses" [ "$rc3" -ne 0 ]
  check_contains "scenario-15 refusal names r2's already-staged operation" "$out3" "already staged from this same pre_op"
}

test_scenario_16_integrate_twice() {
  # Integrate's "already integrated" gate refuses a second call on
  # the same receipt, with the exact phase-aware message and next line.
  local c="scenario-16-integrate-twice"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local out1 rc1=0
  out1="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc1=$?
  check "scenario-16 first integrate exit 0" [ "$rc1" -eq 0 ]

  local out2 rc2=0
  out2="$(sync_run "$work" integrate "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-16 second integrate exit nonzero" [ "$rc2" -ne 0 ]
  check_contains "scenario-16 exact message" "$out2" "✗ already integrated (phase: integrated-clean); nothing integrated again"
  check_contains "scenario-16 next points to finish" "$out2" "next         rbf/scripts/upstream-sync.sh finish $receipt_id"
}

test_scenario_17_finish_nonempty_child() {
  # Finish must refuse when @ is a NON-empty child of
  # master, not just accept any child regardless of its own diff.
  local c="scenario-17-finish-nonempty-child"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1
  printf 'dirty\n' > "$work/dirty.txt"

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-17 exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-17 refusal" "$out" "✗ @ is not master; not verified, nothing run"
  check_not_contains "scenario-17 no verified line" "$out" "✓ verified local master"
}

test_scenario_18_ledger_padding_alignment() {
  # pad_chars must pad by CHARACTER count, not /bin/bash 3.2's own
  # printf '%-Ns', which pads by BYTE count even under a UTF-8 locale
  # (confirmed directly: `printf '%-10s|' "ab…"` is 8 display characters
  # wide before the "|", not 10, under en_CA.UTF-8 and under C alike).
  #
  # A subject cut to exactly 49 chars + "…" can't show this: it always
  # lands AT the 50-char field width, so pad is 0 either way (correct or
  # buggy). The bug only shows on a SHORT subject (well under the field
  # width, so padding is actually added) that merely CONTAINS a
  # multibyte character.
  local c="scenario-18-ledger-padding-alignment"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'l1\nl2\nl3\n' > "$seed/a.txt"
  ( cd "$seed" && git add -A && git commit -qm base2 && git push -q origin master && git push -q upstream master )
  jj_run "$work" git fetch --remote origin >/dev/null 2>&1
  jj_run "$work" bookmark set master -r master@origin >/dev/null 2>&1

  jj_run "$work" new master -m "feat: short" >/dev/null 2>&1
  printf 'f1\nl2\nl3\n' > "$work/a.txt"
  jj_run "$work" new -m "feat: em dash — fix" >/dev/null 2>&1
  printf 'own\n' > "$work/own.txt"
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1

  ( cd "$seed" && printf 'u1\nl2\nl3\n' > a.txt && printf 'collide\n' > own.txt && git add -A && git commit -qm "upstream edits a.txt and adds own.txt" >/dev/null 2>&1 && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  local insp_out rc=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc=$?
  check "scenario-18 inspect exit 0" [ "$rc" -eq 0 ]

  local short_line long_line
  short_line="$(printf '%s\n' "$insp_out" | grep -F 'feat: short')"
  long_line="$(printf '%s\n' "$insp_out" | grep -F 'em dash')"
  check "scenario-18 short row found" [ -n "$short_line" ]
  check "scenario-18 unicode row found" [ -n "$long_line" ]

  # Decode as UTF-8 explicitly (not whatever python3's ambient default
  # is) so this measures DISPLAY characters, matching what pad_chars's
  # own ${#s} counts — never bytes.
  local pos_short pos_long
  pos_short="$(printf '%s' "$short_line" | python3 -c "
import sys
s = sys.stdin.buffer.read().decode('utf-8')
print(s.index('1 region'))
" 2>/dev/null)"
  pos_long="$(printf '%s' "$long_line" | python3 -c "
import sys
s = sys.stdin.buffer.read().decode('utf-8')
print(s.index('1 region'))
" 2>/dev/null)"
  # shellcheck disable=SC2016 # $1/$2 are the nested bash -c's own positional args
  check "scenario-18 region column aligns across a plain row and a multibyte-subject row" \
    bash -c '[ -n "$1" ] && [ -n "$2" ] && [ "$1" -eq "$2" ]' _ "$pos_short" "$pos_long"
}

test_scenario_19_check_plural_boundaries() {
  # plural_word's boundaries in check's own output —
  # 1 stays singular ("1 change", "1 commit"), and a genuinely reachable
  # 0 ("0 upstream-owned files edited", when the fork only adds new
  # files) stays plural.
  local c="scenario-19-check-plural-boundaries"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork edit\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local out
  out="$(sync_run "$work" 2>&1)"
  check_contains "scenario-19 singular fork stack" "$out" "fork stack     1 change; 1 upstream-owned file edited"
  check_contains "scenario-19 singular upstream new" "$out" "upstream new   1 commit since the merge base"

  # Second fixture: the fork only ADDS a new file, editing none of
  # upstream's existing ones — a genuinely reachable 0 count (0 upstream
  # commits since the merge base is unreachable: that state is always
  # "already current" and refuses before this line ever prints).
  local c2="scenario-19-check-plural-boundaries-zero"
  setup_standard_fixture "$c2"
  local work2="$BASE/work"
  local seed2="$BASE/seed"

  printf 'new content\n' > "$work2/new.txt"
  jj_run "$work2" describe -m "feat: adds only" >/dev/null 2>&1
  jj_run "$work2" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed2/up.txt"
  ( cd "$seed2" && git add -A && git commit -qm up && git push -q upstream master )

  local out2
  out2="$(sync_run "$work2" 2>&1)"
  check_contains "scenario-19 zero files edited stays plural" "$out2" "fork stack     1 change; 0 upstream-owned files edited"
}

test_scenario_20_reconcile_marks_conflicted() {
  # An interrupted integrate (jj op integrate succeeded
  # live, but the script died before rewriting the receipt) leaves the
  # receipt reading staged-not-integrated even though the candidate is
  # now active and CONFLICTED. The next command's reconcile must mark it
  # integrated-conflicted, not silently default to integrated-clean —
  # and inspect's own "next" line must then point at resolving,
  # not at integrate again (which would just refuse as already done).
  local c="scenario-20-reconcile-marks-conflicted"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork line\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: conflicting" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream line\n' > "$seed/file.txt"
  ( cd "$seed" && git commit -am up >/dev/null 2>&1 && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1

  cat > "$BASE/bin/jj" <<JJSHIM
#!/bin/sh
if [ "\${INTERRUPT_INTEGRATE:-}" = "1" ] && [ "\$#" -ge 2 ] && [ "\$1" = "op" ] && [ "\$2" = "integrate" ]; then
  "$REAL_JJ" "\$@"
  kill -9 \$PPID 2>/dev/null || true
  exit 137
fi
exec "$REAL_JJ" "\$@"
JJSHIM
  chmod +x "$BASE/bin/jj"
  INTERRUPT_INTEGRATE=1 sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1 || true
  rm -f "$BASE/bin/jj"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  check "scenario-20 receipt still reads staged-not-integrated right after the interrupt" \
    grep -Fq "phase=staged-not-integrated" "$rec_file"

  local insp_out rc=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc=$?
  check "scenario-20 inspect exit 0" [ "$rc" -eq 0 ]
  # Reconcile's own "jj workspace update-stale" really ran here, not
  # just the phase rewrite — this workspace must be readable immediately,
  # the same proof scenario-4 uses for a normal (uninterrupted) integrate.
  check "scenario-20 reconcile left this workspace not stale" jj_run_quiet "$work" status
  check "scenario-20 reconcile marks it integrated-conflicted" \
    grep -Fq "phase=integrated-conflicted" "$rec_file"
  check_contains "scenario-20 next line points at resolving, not integrate" \
    "$insp_out" "next         resolve the remaining conflicts, then rbf/scripts/upstream-sync.sh finish $receipt_id"
  check_not_contains "scenario-20 next line does not send back to integrate" \
    "$insp_out" "next         rbf/scripts/upstream-sync.sh integrate $receipt_id"

  jj_run "$work" new master >/dev/null 2>&1
  local finish_out rc2=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc2=$?
  check "scenario-20 finish refuses remaining conflicts" [ "$rc2" -ne 0 ]
  check_contains "scenario-20 finish names conflicts remain" "$finish_out" "✗ conflicts remain in the fork stack"
}

# ---------------------------------------------------------------------------
# Further hardening for stage's guards, finish's verify-time comparisons,
# and reconcile's own phase bookkeeping.
# ---------------------------------------------------------------------------

test_scenario_21_stage_dirty_master_itself() {
  # @ IS master (not a separate empty child) with
  # an uncommitted file. The guard revset check is the first jj command
  # since check that doesn't --ignore-working-copy, so it snapshots the
  # dirty file straight into source_commit itself — nothing moves OUTSIDE
  # the fork stack, so the existing guard passes, but the receipt's
  # source_commit is now stale. Before the fix: stage exited 0 with
  # "0 changes replayed", staging a divergent duplicate that only failed
  # safe later, at integrate.
  local c="scenario-21-stage-dirty-master-itself"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  local pre_op
  pre_op="$(jj_run "$work" --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)')"

  # @ IS master (no `jj new master` here) — the dirty file lands directly
  # on the source change itself.
  printf 'dirty edit on master itself\n' > "$work/dirty.txt"

  local out rc=0
  out="$(sync_run "$work" stage "$receipt_id" 2>&1)" || rc=$?
  check "scenario-21 exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-21 refusal" "$out" "✗ master was rewritten since check; nothing staged"
  check_not_contains "scenario-21 never claims success" "$out" "✓ staged operation"

  check "scenario-21 receipt stays checked" grep -Fq "phase=checked" "$rec_file"
  check "scenario-21 receipt has no staged_op" grep -Fxq "staged_op=" "$rec_file"

  local post_op
  post_op="$(jj_run "$work" --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)')"
  check "scenario-21 no detached op created" [ "$pre_op" = "$post_op" ]
}

test_scenario_22_finish_verify_amends_master() {
  # A verify command that amends master (same
  # change ID, new commit ID — a `jj describe`) must still be caught by
  # the after-verify comparison, which checks both the change ID and the
  # commit ID.
  local c="scenario-22-finish-verify-amends-master"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'jj describe -r master -m x' 2>&1)" || rc=$?
  check "scenario-22 exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-22 refusal" "$out" "✗ master or the upstream tip moved during verification; not verified, receipt unchanged"
  check_not_contains "scenario-22 no verified line" "$out" "✓ verified local master"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  check "scenario-22 phase stays integrated-clean" grep -Fq "phase=integrated-clean" "$rec_file"
}

test_scenario_23_finish_upstream_moved_before_verify() {
  # The upstream tip is compared before AND after
  # the verify command. Here it moves BEFORE verify ever runs (a fetch
  # outside verify-cmd, unlike scenario-6f2's during-verify fetch) — this
  # must fail fast, before "⋯ verifying" prints, with its own message.
  local c="scenario-23-finish-upstream-moved-before-verify"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  printf 'y\n' > "$seed/up2.txt"
  ( cd "$seed" && git add -A && git commit -qm "upstream advances before finish" && git push -q upstream master )
  jj_run "$work" git fetch --remote upstream >/dev/null 2>&1

  local out rc=0
  out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc=$?
  check "scenario-23 exit nonzero" [ "$rc" -ne 0 ]
  check_contains "scenario-23 refusal" "$out" "✗ the upstream tip moved since check; not verified, nothing run"
  check_not_contains "scenario-23 fails before verifying" "$out" "⋯ verifying"

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  check "scenario-23 receipt not verified" grep -Fq "phase=integrated-clean" "$rec_file"
}

test_scenario_24_reconcile_marks_clean_once_resolved() {
  # Resolving every conflict by hand never rewrites phase= on its
  # own (jj squash doesn't know about the receipt) — the next command's
  # reconcile must upgrade integrated-conflicted to integrated-clean once
  # conflicts() & range is genuinely empty, so finish's own header (and
  # inspect's) stop reading "(integrated-conflicted)" forever.
  local c="scenario-24-reconcile-marks-clean-once-resolved"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  printf 'fork line\n' > "$work/file.txt"
  jj_run "$work" describe -m "feat: conflicting" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'upstream line\n' > "$seed/file.txt"
  ( cd "$seed" && git commit -am up >/dev/null 2>&1 && git push -q upstream master )

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1

  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"
  check "scenario-24 phase is integrated-conflicted right after integrate" \
    grep -Fq "phase=integrated-conflicted" "$rec_file"

  local top_change
  top_change="$(jj_run "$work" log -r master --no-graph -T 'change_id.short(8)')"
  jj_run "$work" new "$top_change" >/dev/null 2>&1
  printf 'resolved\n' > "$work/file.txt"
  jj_run "$work" squash --from "${top_change}..@" --into "$top_change" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  local insp_out rc=0
  insp_out="$(sync_run "$work" inspect "$receipt_id" 2>&1)" || rc=$?
  check "scenario-24 inspect exit 0" [ "$rc" -eq 0 ]
  check_contains "scenario-24 inspect reports integrated-clean" "$insp_out" "(integrated-clean)"
  check "scenario-24 receipt upgraded to integrated-clean" grep -Fq "phase=integrated-clean" "$rec_file"

  local finish_out rc2=0
  finish_out="$(sync_run "$work" finish "$receipt_id" --verify-cmd 'true' 2>&1)" || rc2=$?
  check "scenario-24 finish exit 0" [ "$rc2" -eq 0 ]
  check_contains "scenario-24 finish header says integrated-clean" "$finish_out" "(integrated-clean)"
  check_contains "scenario-24 finish verified" "$finish_out" "✓ verified local master"
}

test_scenario_25_jj_guard_conflicts_query_fails() {
  # Finish's remaining_conflicts, integrate's
  # conf_revs, and check's source_conflicts are each a jj_guard call
  # whose own `|| exit 1` is what actually stops the command. A jj
  # wrapper that fails any `log -r <revset with conflicts()>` call proves
  # each phase stops with jj_guard's own message, rather than silently
  # continuing with an empty value.
  local c="scenario-25-jj-guard-conflicts-query-fails"
  setup_standard_fixture "$c"
  local work="$BASE/work"
  local seed="$BASE/seed"

  cat > "$BASE/bin/jj" <<JJSHIM
#!/bin/sh
if [ "\${FAIL_CONFLICTS_QUERY:-}" = "1" ]; then
  for a in "\$@"; do
    case "\$a" in
      *'conflicts()'*)
        echo "simulated jj failure evaluating conflicts()" >&2
        exit 1
        ;;
    esac
  done
fi
exec "$REAL_JJ" "\$@"
JJSHIM
  chmod +x "$BASE/bin/jj"

  printf 'fork\n' > "$work/f.txt"
  jj_run "$work" describe -m "feat: f" >/dev/null 2>&1
  jj_run "$work" bookmark set master -r @ >/dev/null 2>&1
  printf 'x\n' > "$seed/up.txt"
  ( cd "$seed" && git add -A && git commit -qm up && git push -q upstream master )

  # Phase 1: check (V4).
  local check_fail_out rc1=0
  check_fail_out="$(FAIL_CONFLICTS_QUERY=1 sync_run "$work" 2>&1)" || rc1=$?
  check "scenario-25 check stops via jj_guard" [ "$rc1" -ne 0 ]
  check_contains "scenario-25 check ✗ jj failed" "$check_fail_out" "✗ jj failed:"
  check "scenario-25 check wrote no receipt" [ ! -d "$BASE/state/herdr-rbf-upstream-sync" ]

  local check_out receipt_id
  check_out="$(sync_run "$work" 2>&1)"
  receipt_id="$(printf '%s\n' "$check_out" | sed -n 's/^next *rbf\/scripts\/upstream-sync.sh stage \(.*\)$/\1/p')"
  sync_run "$work" stage "$receipt_id" >/dev/null 2>&1
  local rec_file="$BASE/state/herdr-rbf-upstream-sync/$receipt_id.receipt"

  # Phase 2: integrate (V3). Not yet integrated live, so reconcile's own
  # (unrelated) conflicts() read never runs — only integrate's own
  # conf_revs jj_guard call is on the path.
  local int_fail_out rc2=0
  int_fail_out="$(FAIL_CONFLICTS_QUERY=1 sync_run "$work" integrate "$receipt_id" 2>&1)" || rc2=$?
  check "scenario-25 integrate stops via jj_guard" [ "$rc2" -ne 0 ]
  check_contains "scenario-25 integrate ✗ jj failed" "$int_fail_out" "✗ jj failed:"
  check "scenario-25 integrate receipt unchanged" grep -Fq "phase=staged-not-integrated" "$rec_file"

  sync_run "$work" integrate "$receipt_id" >/dev/null 2>&1
  jj_run "$work" new master >/dev/null 2>&1

  # Phase 3: finish (V2).
  local finish_fail_out rc3=0
  finish_fail_out="$(FAIL_CONFLICTS_QUERY=1 sync_run "$work" finish "$receipt_id" --verify-cmd true 2>&1)" || rc3=$?
  check "scenario-25 finish stops via jj_guard" [ "$rc3" -ne 0 ]
  check_contains "scenario-25 finish ✗ jj failed" "$finish_fail_out" "✗ jj failed:"
  check "scenario-25 finish receipt unchanged" grep -Fq "phase=integrated-clean" "$rec_file"

  rm -f "$BASE/bin/jj"
}

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

setup_root

run_case() {
  local c="$1"
  printf '=== Running case: %s ===\n' "$c"
  case "$c" in
    scenario-1) test_scenario_1 ;;
    scenario-2) test_scenario_2 ;;
    scenario-3) test_scenario_3 ;;
    scenario-3b-concurrent-op) test_scenario_3b_stage_stale ;;
    scenario-3c-unknown-op) test_scenario_3c_unknown_staged_op ;;
    scenario-4) test_scenario_4 ;;
    scenario-5) test_scenario_5 ;;
    scenario-5b-no-verify-cmd) test_scenario_5b_no_verify_cmd ;;
    scenario-6) test_scenario_6 ;;
    scenario-6b-master-moved) test_scenario_6b_master_moved ;;
    scenario-6c-not-integrated) test_scenario_6c_not_integrated ;;
    scenario-6d-change-moved-off-stack) test_scenario_6d_change_moved_off_stack ;;
    scenario-6e-verify-cmd-not-from-receipt) test_scenario_6e_verify_cmd_not_from_receipt ;;
    scenario-8) test_scenario_8 ;;
    scenario-8e-upstream-branch-main) test_scenario_8e_upstream_branch_main ;;
    scenario-8f-origin-mode-integrate) test_scenario_8f_origin_mode_integrate ;;
    scenario-9) test_scenario_9 ;;
    scenario-9c-check-detects-stale) test_scenario_9c_check_detects_stale ;;
    scenario-10) test_scenario_10 ;;
    scenario-11-working-copy) test_scenario_11_working_copy ;;
    scenario-11-conflicted-source) test_scenario_11_conflicted_source ;;
    scenario-11-mid-stack-checkout) test_scenario_11_mid_stack_checkout ;;
    scenario-11-skip-verify) test_scenario_11_skip_verify ;;
    scenario-11-worktree-switch) test_scenario_11_worktree_switch ;;
    scenario-11-already-current) test_scenario_11_already_current ;;
    scenario-11-missing-upstream-remote) test_scenario_11_missing_upstream_remote ;;
    scenario-11-missing-upstream-branch) test_scenario_11_missing_upstream_branch ;;
    scenario-11-finish-rerun) test_scenario_11_finish_rerun ;;
    scenario-12) test_scenario_12 ;;
    scenario-13) test_scenario_13 ;;
    scenario-13b-dropped-validation) test_scenario_13b_dropped_validation ;;
    scenario-2b-check-master-conflicted) test_scenario_2b_check_master_conflicted ;;
    scenario-4c-chain-inherit-only) test_scenario_4c_chain_inherit_only ;;
    scenario-6f-master-moved-during-verify) test_scenario_6f_finish_master_moved_during_verify ;;
    scenario-6f2-upstream-moved-during-verify) test_scenario_6f2_finish_upstream_moved_during_verify ;;
    scenario-6g-finish-master-conflicted) test_scenario_6g_finish_master_conflicted ;;
    scenario-6h-finish-origin-moved-since-check) test_scenario_6h_finish_origin_moved_since_check ;;
    scenario-7-ledger-log) test_scenario_7_ledger_log ;;
    scenario-8g-finish-no-local-master) test_scenario_8g_finish_no_local_master ;;
    scenario-14-stage-path-contains-stage) test_scenario_14_stage_path_contains_stage ;;
    scenario-15-stage-guards) test_scenario_15_stage_guards ;;
    scenario-16-integrate-twice) test_scenario_16_integrate_twice ;;
    scenario-17-finish-nonempty-child) test_scenario_17_finish_nonempty_child ;;
    scenario-18-ledger-padding-alignment) test_scenario_18_ledger_padding_alignment ;;
    scenario-19-check-plural-boundaries) test_scenario_19_check_plural_boundaries ;;
    scenario-20-reconcile-marks-conflicted) test_scenario_20_reconcile_marks_conflicted ;;
    scenario-21-stage-dirty-master-itself) test_scenario_21_stage_dirty_master_itself ;;
    scenario-22-finish-verify-amends-master) test_scenario_22_finish_verify_amends_master ;;
    scenario-23-finish-upstream-moved-before-verify) test_scenario_23_finish_upstream_moved_before_verify ;;
    scenario-24-reconcile-marks-clean-once-resolved) test_scenario_24_reconcile_marks_clean_once_resolved ;;
    scenario-25-jj-guard-conflicts-query-fails) test_scenario_25_jj_guard_conflicts_query_fails ;;
    *)
      echo "Unknown case: $c" >&2
      echo "Available cases:" >&2
      printf '%s\n' "$ALL_CASES" >&2
      exit 2
      ;;
  esac
}

if [ -n "$CASE" ]; then
  run_case "$CASE"
else
  for c in $ALL_CASES; do
    run_case "$c"
  done
fi

if [ "$FAILS" -gt 0 ]; then
  printf '\nTotal failures: %d\n' "$FAILS" >&2
  exit 1
else
  printf '\nAll checks passed.\n'
  exit 0
fi
