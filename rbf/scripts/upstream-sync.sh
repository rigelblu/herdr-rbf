#!/bin/bash

# Staged, safe upstream-sync workflow for herdr-rbf fork.
# Phases: check -> stage -> inspect -> integrate -> (resolve by hand) -> finish
#
# Commands:
#   check (default)       fetch upstream, report divergence, write receipt
#   stage <receipt>       rebase fork stack as a detached operation
#   inspect <receipt>     show staged result, conflict ledger, change preview
#   integrate <receipt>   apply exact staged op, report bottom-up resolve steps
#   finish <receipt>      verify master's tree and record verified-local-master
#
# Bash 3.2 compatible. Uses jj 0.45.1. No network publish or push commands.

set -uo pipefail

REPO=""
STATE_DIR="${UPSTREAM_SYNC_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-rbf-upstream-sync}"
LOG="$HOME/Library/Logs/herdr-rbf-upstream-sync.log"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-master}"
VERIFY_CMD="${UPSTREAM_SYNC_VERIFY_CMD:-}"

usage() {
  cat <<'USAGE'
usage: rbf/scripts/upstream-sync.sh <command> [<receipt>] [options]

Bring upstream Herdr into this fork one checked step at a time. Nothing is
pushed, installed, or released.

  check                 fetch upstream, report the divergence, write a receipt
                        (the default with no arguments; --check-only is check)
  stage <receipt>       rebase the fork stack as a detached operation
  inspect <receipt>     show the staged result and each change's conflicts
  integrate <receipt>   apply that exact operation; print the resolve steps
  finish <receipt>      prove every fork change survived, verify master's
                        tree, and record it verified

  <receipt> is the path check prints, or its run ID (20260922-1412)

options
  --verify-cmd <cmd>    command finish runs (or UPSTREAM_SYNC_VERIFY_CMD)
  --dropped <change>    finish: a fork change removed on purpose; repeatable
  --log-path <path>     default ~/Library/Logs/herdr-rbf-upstream-sync.log

environment
  UPSTREAM_BRANCH          upstream branch (default: master)
  UPSTREAM_SYNC_STATE_DIR  receipt directory
                           (default ~/.local/state/herdr-rbf-upstream-sync)
USAGE
}

say() { printf '%s\n' "$*"; }

log_msg() {
  local msg="$*"
  mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$msg" >> "$LOG" 2>/dev/null || true
}

# Run a jj command whose own output belongs only in the log, never on
# stdout — jj's own fetch, rebase and integrate output would otherwise
# drown out this script's own report lines. Sets JJ_OUT to the combined
# output and returns
# jj's own exit status, so callers decide how to react instead of this
# helper swallowing anything.
jj_logged() {
  local rc=0
  JJ_OUT="$(jj "$@" 2>&1)" || rc=$?
  if [ -n "$JJ_OUT" ]; then
    log_msg "jj $* -> $JJ_OUT"
  fi
  return $rc
}

# Run a jj query needed for a guard (a revset that decides whether a
# command proceeds or refuses). A jj query that simply matches nothing is
# exit 0 with empty output: a normal, valid result. A nonzero exit is a
# genuine jj failure (a bad revset, a missing ref, a stale workspace) and
# must stop the command with a ✗ line, never be treated as "empty" or
# silently ignored — a jj failure on a guard path must never be
# swallowed and mistaken for a clean result.
#
# This is always invoked as `x="$(jj_guard ...)"`,
# and command substitution always runs in a subshell — so `exit` here only
# ends that subshell; the caller never sees it and keeps going with
# whatever text this printed as $x. Two things fix that: the message goes
# to stderr (never captured into $x), and this `return`s 1, so `$?` after
# the substitution reflects the failure and every call site can act on it
# (`x="$(jj_guard ...)" || exit 1`).
jj_guard() {
  local out rc=0
  out="$(jj "$@" 2>&1)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if printf '%s' "$out" | grep -qi 'working copy is stale'; then
      say "✗ this workspace is stale; nothing done" >&2
      say "  $(printf '%s' "$out" | head -1)" >&2
      say "" >&2
      say "next         jj workspace update-stale" >&2
    elif printf '%s' "$out" | grep -qi 'is conflicted'; then
      # Every jj_guard call resolves a commit-range revset except the one
      # that reads `master` itself in finish's stack-tip check — a
      # conflicted bookmark NAME is the only "is conflicted" jj_guard can
      # actually hit, so the fix is always this one, the same row `check`
      # already prints for the same condition.
      say "✗ master is conflicted; not verified, nothing run" >&2
      say "fix once     jj bookmark set master -r <rev>" >&2
      say "next         rbf/scripts/upstream-sync.sh finish ${RUN_ID:-<receipt>}" >&2
    else
      say "✗ jj failed: $out" >&2
    fi
    return 1
  fi
  printf '%s' "$out"
}

# A cheap, harmless jj read that also serves as this workspace's staleness
# canary. Never swallow the stale-workspace error as some unrelated guard's
# failure — a stale workspace needs its own clear diagnosis, not a
# misleading one from whatever command happened to notice it first.
refuse_if_stale_workspace() {
  local out rc=0
  out="$(jj status 2>&1 >/dev/null)" || rc=$?
  if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi 'working copy is stale'; then
    say "✗ this workspace is stale; nothing done"
    say "  $(printf '%s' "$out" | head -1)"
    say ""
    say "next         jj workspace update-stale"
    exit 1
  fi
}

plural_word() {
  local n="$1" singular="$2" plural="$3"
  if [ "$n" -eq 1 ]; then printf '%s' "$singular"; else printf '%s' "$plural"; fi
}

# Right-pad a string to a character-count width (not bash 3.2's byte-based
# printf '%-Ns', which under-pads a string ending in a multi-byte glyph
# like "…").
pad_chars() {
  local s="$1" width="$2"
  local len="${#s}"
  local pad=$((width - len))
  printf '%s' "$s"
  if [ "$pad" -gt 0 ]; then
    printf '%*s' "$pad" ''
  fi
}

# An operation ID of all zeros is jj's own literal root-of-the-op-log ID:
# it always exists and always resolves via --at-op, but no real `stage`
# ever records it, so it's never a legitimate staged_op. Guards against
# both --at-op "resolving" it and a naive substring match in the op log
# accidentally matching it.
is_bogus_op_id() {
  local id="$1"
  [ -z "${id//0/}" ]
}

display_path() {
  local p="$1"
  if [ -n "$HOME" ] && [ "$p" = "$HOME" ]; then
    printf '~'
  elif [ -n "$HOME" ] && [[ "$p" == "$HOME"/* ]]; then
    # shellcheck disable=SC2088 # literal display text, not filesystem tilde expansion
    printf '~/%s' "${p#"$HOME"/}"
  else
    printf '%s' "$p"
  fi
}

resolve_receipt_file() {
  local arg="$1"
  if [[ "$arg" == *"/"* ]]; then
    RECEIPT_FILE="$arg"
  elif [[ "$arg" == *.receipt ]]; then
    RECEIPT_FILE="$STATE_DIR/$arg"
  else
    RECEIPT_FILE="$STATE_DIR/$arg.receipt"
  fi
  if [ ! -f "$RECEIPT_FILE" ]; then
    say "Error: receipt not found: $RECEIPT_FILE" >&2
    exit 1
  fi
  RUN_ID="$(basename "$RECEIPT_FILE" .receipt)"
}

write_receipt_atomic() {
  local target="$1"
  local content="$2"
  mkdir -p "$(dirname "$target")"
  local tmp_target="${target}.tmp.$RANDOM.$$"
  printf '%s\n' "$content" > "$tmp_target"
  if ! mv "$tmp_target" "$target"; then
    rm -f "$tmp_target"
    say "Error: failed to write receipt atomically to $target" >&2
    return 1
  fi
}

get_rec() {
  grep "^$1=" "$RECEIPT_FILE" 2>/dev/null | head -1 | cut -d= -f2-
}

get_rec_all() {
  grep "^$1=" "$RECEIPT_FILE" 2>/dev/null | cut -d= -f2-
}

# Reconcile a receipt against live jj state before any command acts on it.
# An interrupted `integrate` can leave a receipt
# reading staged-not-integrated after `jj op integrate` already succeeded;
# every command that takes a receipt notices and moves the receipt forward,
# not just `finish`. Sets RECON_PHASE to the (possibly updated) phase.
#
# Uses only --ignore-working-copy reads for its own comparison, so calling
# this first never snapshots a dirty working copy ahead of a command's own
# guard (e.g. stage's guard revset, which must see a dirty file itself).
reconcile_receipt() {
  local phase staged_op upstream_commit source_change_id
  phase="$(get_rec phase)"
  staged_op="$(get_rec staged_op)"
  upstream_commit="$(get_rec upstream_commit)"
  source_change_id="$(get_rec source_change_id)"

  if [ "$phase" = "staged-not-integrated" ] && [ -n "$staged_op" ] && ! is_bogus_op_id "$staged_op"; then
    local op_list op_rc=0
    op_list="$(jj --ignore-working-copy op log --no-graph -T 'id ++ "\n"' 2>&1)" || op_rc=$?
    if [ "$op_rc" -ne 0 ]; then
      say "✗ jj failed reading the operation log: $op_list"
      exit 1
    fi
    if printf '%s\n' "$op_list" | grep -Fq "$staged_op"; then
      # The staged operation is already active: integrate ran, but the
      # rename to phase=integrated-* (and this workspace's own
      # update-stale) didn't complete. Finish both now.
      local stale_out stale_rc=0
      stale_out="$(jj workspace update-stale 2>&1)" || stale_rc=$?
      if [ -n "$stale_out" ]; then
        log_msg "jj workspace update-stale -> $stale_out"
      fi
      if [ "$stale_rc" -ne 0 ] && ! printf '%s' "$stale_out" | grep -qi 'already.*up.to.date\|not stale\|nothing to do'; then
        say "✗ jj workspace update-stale failed: $stale_out"
        exit 1
      fi

      local conf_rem conf_rc=0
      conf_rem="$(jj log -r "conflicts() & ${upstream_commit}..heads(::${source_change_id})" --no-graph -T '"."' 2>&1)" || conf_rc=$?
      if [ "$conf_rc" -ne 0 ]; then
        say "✗ jj failed checking conflicts: $conf_rem"
        exit 1
      fi
      if [ -n "$conf_rem" ]; then
        phase="integrated-conflicted"
      else
        phase="integrated-clean"
      fi
      local old_content new_content
      old_content="$(grep -v '^phase=' "$RECEIPT_FILE" | grep -v '^updated_at=')"
      new_content="$(cat <<REC
phase=$phase
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
$old_content
REC
)"
      write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
      log_msg "reconciled run_id=$RUN_ID phase=$phase"
    fi
  elif [ "$phase" = "integrated-conflicted" ]; then
    # Resolving every conflict (bottom-up, by hand) never rewrites
    # phase= itself — it's a receipt field, not something `jj squash`
    # knows about. Without this, finish's own header keeps reading
    # "(integrated-conflicted)" forever, even once finish's own conflict
    # check would already pass. Re-check live and upgrade the phase when
    # nothing's left; finish still refuses on its own if anything remains
    # (this only ever moves phase toward -clean, never the reverse).
    local conf_rem conf_rc=0
    conf_rem="$(jj log -r "conflicts() & ${upstream_commit}..heads(::${source_change_id})" --no-graph -T '"."' 2>&1)" || conf_rc=$?
    if [ "$conf_rc" -eq 0 ] && [ -z "$conf_rem" ]; then
      phase="integrated-clean"
      local old_content new_content
      old_content="$(grep -v '^phase=' "$RECEIPT_FILE" | grep -v '^updated_at=')"
      new_content="$(cat <<REC
phase=$phase
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
$old_content
REC
)"
      write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
      log_msg "reconciled run_id=$RUN_ID phase=$phase"
    fi
  fi

  RECON_PHASE="$phase"
}

parse_rename_or_copy_paths() {
  local display_path="$1"
  local prefix renamed suffix old_middle new_middle
  if [[ "$display_path" == *"{"* && "$display_path" == *" => "* && "$display_path" == *"}"* ]]; then
    prefix="${display_path%%\{*}"
    renamed="${display_path#*\{}"
    suffix="${renamed#*\}}"
    renamed="${renamed%%\}*}"
    old_middle="${renamed%% => *}"
    new_middle="${renamed#* => }"
    printf '%s\n%s\n' "${prefix}${old_middle}${suffix}" "${prefix}${new_middle}${suffix}"
    return 0
  fi
  if [[ "$display_path" == *" => "* ]]; then
    printf '%s\n%s\n' "${display_path%% => *}" "${display_path#* => }"
    return 0
  fi
  return 1
}

classify_divergence() {
  local fork_base="$1"
  local stack_tip="$2"
  OWNED_FILES=""
  HOOKED_FILES=""
  DELETED_FILES=""

  local line status rest paths old_path new_path
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    status="${line%% *}"
    rest="${line#* }"
    case "$status" in
      A) OWNED_FILES="${OWNED_FILES}${rest}"$'\n' ;;
      M) HOOKED_FILES="${HOOKED_FILES}${rest}"$'\n' ;;
      D) DELETED_FILES="${DELETED_FILES}${rest}"$'\n' ;;
      R)
        if paths="$(parse_rename_or_copy_paths "$rest")"; then
          old_path="$(printf '%s\n' "$paths" | sed -n '1p')"
          new_path="$(printf '%s\n' "$paths" | sed -n '2p')"
          OWNED_FILES="${OWNED_FILES}${new_path}"$'\n'
          DELETED_FILES="${DELETED_FILES}${old_path}"$'\n'
        else
          HOOKED_FILES="${HOOKED_FILES}${rest}"$'\n'
        fi
        ;;
      C)
        if paths="$(parse_rename_or_copy_paths "$rest")"; then
          new_path="$(printf '%s\n' "$paths" | sed -n '2p')"
          OWNED_FILES="${OWNED_FILES}${new_path}"$'\n'
        else
          OWNED_FILES="${OWNED_FILES}${rest}"$'\n'
        fi
        ;;
    esac
  done < <(jj diff --from "$fork_base" --to "$stack_tip" --summary 2>/dev/null || true)
}

classify_file() {
  local f="$1"
  if printf '%s' "$HOOKED_FILES" | grep -Fxq "$f"; then
    printf 'upstream-file edit'
  elif printf '%s' "$OWNED_FILES" | grep -Fxq "$f"; then
    printf 'fork-owned collision'
  elif printf '%s' "$DELETED_FILES" | grep -Fxq "$f"; then
    printf 'deleted or renamed by fork'
  else
    printf 'unknown'
  fi
}

count_file_regions() {
  local op_arg="$1"
  local rev="$2"
  local file="$3"
  local content
  if [ -n "$op_arg" ]; then
    content="$(jj --at-op "$op_arg" file show -r "$rev" "$file" 2>/dev/null || true)"
  else
    content="$(jj file show -r "$rev" "$file" 2>/dev/null || true)"
  fi
  if [ -z "$content" ]; then
    echo 0
    return
  fi
  local m
  m="$(printf '%s\n' "$content" | sed -n 's/^<<<<<<< conflict [0-9]* of \([0-9]*\).*/\1/p' | tail -1)"
  echo "${m:-0}"
}

# For a change (optionally at a given jj operation), compute the files
# where it adds its OWN new conflict regions: its count minus its parent's,
# per path, floor 0. Both the ledger (inspect) and the resolve
# rows (integrate) use this same rule, so a change's own conflicts always
# mean the same thing everywhere they're shown.
#
# Sets OWN_CONFLICT_PATHS (newline list of paths), OWN_CONFLICT_PAIRS
# (newline list of "path count"), and OWN_CONFLICT_TOTAL (sum of counts).
compute_own_conflicts() {
  local op_arg="$1" ch="$2"
  local conf_files
  if [ -n "$op_arg" ]; then
    conf_files="$(jj --at-op "$op_arg" log -r "$ch" --no-graph -T 'self.conflicted_files().map(|e| e.path() ++ "\n").join("")' 2>/dev/null || true)"
  else
    conf_files="$(jj log -r "$ch" --no-graph -T 'self.conflicted_files().map(|e| e.path() ++ "\n").join("")' 2>/dev/null || true)"
  fi
  OWN_CONFLICT_PATHS=""
  OWN_CONFLICT_PAIRS=""
  OWN_CONFLICT_TOTAL=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    local child_reg parent_reg own_reg
    child_reg="$(count_file_regions "$op_arg" "$ch" "$f")"
    parent_reg="$(count_file_regions "$op_arg" "${ch}-" "$f")"
    own_reg=$((child_reg - parent_reg))
    [ "$own_reg" -lt 0 ] && own_reg=0
    if [ "$own_reg" -gt 0 ]; then
      OWN_CONFLICT_PATHS="${OWN_CONFLICT_PATHS}${f}"$'\n'
      OWN_CONFLICT_PAIRS="${OWN_CONFLICT_PAIRS}${f} ${own_reg}"$'\n'
      OWN_CONFLICT_TOTAL=$((OWN_CONFLICT_TOTAL + own_reg))
    fi
  done <<< "$conf_files"
}

# ---------------------------------------------------------------------------
# Phase 1: check
# ---------------------------------------------------------------------------

cmd_check() {
  refuse_if_stale_workspace

  local upstream_ref="${UPSTREAM_BRANCH}@upstream"

  # 1. Remotes check
  if ! jj git remote list 2>/dev/null | awk '{print $1}' | grep -Fxq "upstream"; then
    say "✗ no upstream remote; nothing fetched, no receipt written"
    say "fix once     git remote add upstream <url>"
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # 2. Source selection rule
  local has_master=0
  local tracks_upstream=0
  local tracks_origin=0
  local master_probe_out master_probe_rc=0

  master_probe_out="$(jj log -r 'master' --no-graph -T 'commit_id' 2>&1)" || master_probe_rc=$?
  if [ "$master_probe_rc" -eq 0 ]; then
    has_master=1
    if jj bookmark list --all-remotes -T 'if(self.name() == "master" && self.remote() == "upstream" && self.tracked(), "yes\n")' 2>/dev/null | grep -Fq "yes"; then
      tracks_upstream=1
    fi
    if jj bookmark list --all-remotes -T 'if(self.name() == "master" && self.remote() == "origin" && self.tracked(), "yes\n")' 2>/dev/null | grep -Fq "yes"; then
      tracks_origin=1
    fi
  elif printf '%s' "$master_probe_out" | grep -qi 'is conflicted'; then
    # A conflicted master is a distinct case from
    # "doesn't exist". Falling back to master@origin here would silently
    # drop unpushed fork work that only local master carries.
    say "✗ master is conflicted; nothing fetched, no receipt written"
    say "fix once     jj bookmark set master -r <rev>"
    exit 1
  fi

  if [ "$has_master" -eq 1 ] && [ "$tracks_upstream" -eq 1 ]; then
    say "✗ master tracks master@upstream; nothing fetched, no receipt written"
    say "  master has to track master@origin so it names the fork, not upstream"
    say ""
    say "fix once     jj bookmark untrack master@upstream"
    say "             jj bookmark set master -r master@origin --allow-backwards"
    say "             jj bookmark track master@origin"
    say "             jj config set --repo 'revset-aliases.\"immutable_heads()\"' 'builtin_immutable_heads() | remote_bookmarks(remote=exact:\"origin\")'"
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  local source_ref=""
  if [ "$has_master" -eq 1 ]; then
    source_ref="master"
  elif jj log -r 'master@origin' --no-graph -T 'commit_id' >/dev/null 2>&1; then
    source_ref="master@origin"
  else
    say "✗ no fork source found; master and master@origin missing" >&2
    exit 1
  fi

  local source_commit source_change_id
  source_commit="$(jj log -r "$source_ref" --no-graph -T 'commit_id.short(8)' 2>/dev/null)"
  source_change_id="$(jj log -r "$source_ref" --no-graph -T 'change_id.short(8)' 2>/dev/null)"

  # The header always opens check, before fetching. Only the fetch tells
  # whether upstream is already in the fork, and deciding afterwards would
  # leave the terminal silent through a slow fetch. Refusals that stop
  # before fetching (above) still open straight with their ✗ line.
  say "herdr-rbf upstream sync — check"
  say "⋯ fetching upstream"
  if ! jj_logged git fetch --remote upstream; then
    say "✗ failed to fetch upstream remote; nothing staged, no receipt written" >&2
    exit 1
  fi

  local upstream_commit
  upstream_commit="$(jj log -r "$upstream_ref" --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ -z "$upstream_commit" ]; then
    say "✗ ${upstream_ref} not found after fetching upstream; no receipt written"
    say "  configure the 'upstream' remote or set UPSTREAM_BRANCH"
    exit 1
  fi

  say "✓ fetched upstream; $upstream_ref $upstream_commit"

  # Check if source range already holds conflicts
  local source_conflicts
  source_conflicts="$(jj_guard log -r "conflicts() & ::${source_commit}" --no-graph -T 'change_id.short(8) ++ "\n"')" || exit 1
  if [ -n "$source_conflicts" ]; then
    say "✗ conflicts in the source range; nothing staged, no receipt written"
    printf '%s\n' "$source_conflicts" | while IFS= read -r c; do
      [ -n "$c" ] && say "  $c"
    done
    exit 1
  fi

  # Check if upstream is already in fork
  # If heads(::source | ::upstream) is just source, upstream is ancestor
  local heads_check
  heads_check="$(jj log -r "heads(::${source_commit} | ::${upstream_commit})" --no-graph -T 'commit_id.short(8) ++ "\n"' 2>/dev/null || true)"
  if [ "$heads_check" = "$source_commit" ]; then
    say "✓ upstream is already in the fork; nothing to stage, no receipt written"
    exit 0
  fi

  # Merge base
  local fork_base
  fork_base="$(jj log -r "heads(::${source_commit} & ::${upstream_commit})" --no-graph -T 'commit_id.short(8)' 2>/dev/null | head -1)"
  if [ -z "$fork_base" ]; then
    say "✗ no merge base found between fork and upstream" >&2
    exit 1
  fi

  local upstream_new_count fork_stack_count
  upstream_new_count="$(jj log -r "${fork_base}..${upstream_commit}" --no-graph -T '"."' 2>/dev/null | wc -c | tr -d ' ')"
  fork_stack_count="$(jj log -r "${fork_base}..${source_commit}" --no-graph -T '"."' 2>/dev/null | wc -c | tr -d ' ')"

  classify_divergence "$fork_base" "$source_commit"
  local files_edited_count
  files_edited_count="$(printf '%s' "$HOOKED_FILES" | grep -c '' || true)"

  # Bookmarks on the stack. The bare `bookmarks` keyword lists an
  # UNTRACKED remote bookmark's name too (jj shows it there so `jj log`
  # can display "name@remote" for a deleted-locally-but-still-on-the-
  # remote bookmark) — filter to local bookmarks only, since only those
  # move with the stack; a remote-only ref can't be carried by a rebase.
  local bms_on_stack
  bms_on_stack="$(jj log -r "bookmarks() & ::${source_commit} ~ ::${fork_base}" --no-graph -T 'bookmarks.filter(|b| !b.remote()).map(|b| b.name()).join(" ") ++ "\n"' 2>/dev/null | tr '\n' ' ' | xargs)"
  local bms_list
  bms_list="$(printf '%s' "$bms_on_stack" | tr ' ' '\n' | sort -u | paste -sd, - | sed 's/,/, /g')"

  local pre_op
  pre_op="$(jj op log --no-graph --limit 1 -T 'id.short(12)' 2>/dev/null)"

  local origin_commit
  origin_commit="$(jj log -r master@origin --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"

  # Generate run ID
  local base_run_id
  base_run_id="$(date '+%Y%m%d-%H%M')"
  local run_id="$base_run_id"
  local suffix=2
  while [ -f "$STATE_DIR/$run_id.receipt" ]; do
    run_id="${base_run_id}-${suffix}"
    suffix=$((suffix + 1))
  done

  local receipt_target="$STATE_DIR/$run_id.receipt"

  # Format bookmarks line
  local bms_display
  if [ -n "$bms_list" ]; then
    bms_display="$bms_list (move with the stack)"
  else
    bms_display="none"
  fi

  local source_extra=""
  if [ "$source_ref" = "master" ] && [ "$tracks_origin" -eq 1 ]; then
    source_extra=" (tracks master@origin)"
  fi

  printf '  %-14s %s  %s %s%s\n' "source" "$source_ref" "$source_change_id" "$source_commit" "$source_extra"
  printf '  %-14s %s  %s\n' "upstream" "$upstream_ref" "$upstream_commit"
  printf '  %-14s %s\n' "merge base" "$fork_base"
  printf '  %-14s %d %s; %d %s edited\n' "fork stack" "$fork_stack_count" "$(plural_word "$fork_stack_count" change changes)" "$files_edited_count" "$(plural_word "$files_edited_count" 'upstream-owned file' 'upstream-owned files')"
  printf '  %-14s %d %s since the merge base\n' "upstream new" "$upstream_new_count" "$(plural_word "$upstream_new_count" commit commits)"
  printf '  %-14s %s\n' "bookmarks" "$bms_display"
  printf '  %-14s %s\n' "receipt" "$(display_path "$receipt_target")"
  printf '  %-14s %s\n' "log" "$(display_path "$LOG")"
  say ""
  say "✓ checked; nothing rewritten, no bookmark moved"
  say "next         rbf/scripts/upstream-sync.sh stage $run_id"

  # Capture change map
  local change_map_lines
  change_map_lines="$(jj log -r "${fork_base}..${source_commit}" --no-graph -T '"change=" ++ change_id.short(8) ++ ":" ++ commit_id.short(8) ++ ":" ++ description.first_line() ++ "\n"' 2>/dev/null)"

  # Capture local bookmarks with commit ids
  local bm_pairs=""
  for b in $(printf '%s' "$bms_on_stack" | tr ' ' '\n' | sort -u); do
    [ -z "$b" ] && continue
    local b_commit
    b_commit="$(jj log -r "$b" --no-graph -T 'commit_id.short(8)' 2>/dev/null)"
    if [ -n "$bm_pairs" ]; then
      bm_pairs="${bm_pairs},${b}:${b_commit}"
    else
      bm_pairs="${b}:${b_commit}"
    fi
  done

  # Write receipt
  local receipt_content
  receipt_content="$(cat <<REC
version=1
run_id=$run_id
phase=checked
repo_root=$REPO
created_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
upstream_branch=$UPSTREAM_BRANCH
upstream_ref=$upstream_ref
upstream_commit=$upstream_commit
source_ref=$source_ref
source_commit=$source_commit
source_change_id=$source_change_id
merge_base=$fork_base
origin_commit=$origin_commit
pre_op=$pre_op
staged_op=
log_path=$LOG
bookmarks=$bm_pairs
hooked_files=$(printf '%s' "$HOOKED_FILES" | tr '\n' ',' | sed 's/,$//')
owned_files=$(printf '%s' "$OWNED_FILES" | tr '\n' ',' | sed 's/,$//')
deleted_files=$(printf '%s' "$DELETED_FILES" | tr '\n' ',' | sed 's/,$//')
$change_map_lines
REC
)"

  write_receipt_atomic "$receipt_target" "$receipt_content" || exit 1
  log_msg "checked run_id=$run_id pre_op=$pre_op"
}

# ---------------------------------------------------------------------------
# Phase 2: stage
# ---------------------------------------------------------------------------

cmd_stage() {
  local rec_arg="${1:-}"
  if [ -z "$rec_arg" ]; then
    say "Error: stage requires a receipt argument." >&2
    exit 1
  fi
  resolve_receipt_file "$rec_arg"
  reconcile_receipt

  local phase pre_op source_ref source_commit source_change_id upstream_ref upstream_commit staged_op
  phase="$RECON_PHASE"
  pre_op="$(get_rec pre_op)"
  source_ref="$(get_rec source_ref)"
  source_commit="$(get_rec source_commit)"
  source_change_id="$(get_rec source_change_id)"
  upstream_ref="$(get_rec upstream_ref)"
  upstream_commit="$(get_rec upstream_commit)"
  staged_op="$(get_rec staged_op)"

  # A receipt already staged (or further along) never gets staged again
  # (Reliability: "it never silently creates a second rewrite").
  if [ -n "$staged_op" ]; then
    say "✗ already staged as operation $staged_op; nothing staged again"
    say ""
    say "next         rbf/scripts/upstream-sync.sh inspect $RUN_ID"
    exit 1
  fi

  # A detached staging operation never becomes the op log head, so
  # the active-operation check below can't see that some OTHER receipt
  # already staged from this same pre_op — that would silently create a
  # second detached rewrite of the same content. Scan sibling receipts.
  local other_receipt
  for other_receipt in "$STATE_DIR"/*.receipt; do
    [ -e "$other_receipt" ] || continue
    [ "$other_receipt" = "$RECEIPT_FILE" ] && continue
    local other_pre_op other_staged_op other_run_id
    other_pre_op="$(grep '^pre_op=' "$other_receipt" 2>/dev/null | head -1 | cut -d= -f2-)"
    other_staged_op="$(grep '^staged_op=' "$other_receipt" 2>/dev/null | head -1 | cut -d= -f2-)"
    if [ -n "$other_pre_op" ] && [ "$other_pre_op" = "$pre_op" ] && [ -n "$other_staged_op" ]; then
      other_run_id="$(basename "$other_receipt" .receipt)"
      say "✗ $other_run_id already staged from this same pre_op as operation $other_staged_op; nothing staged again"
      say ""
      say "next         rbf/scripts/upstream-sync.sh inspect $other_run_id"
      exit 1
    fi
  done

  # Active operation check
  local active_op
  active_op="$(jj --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)' 2>/dev/null)"
  if [ "$active_op" != "$pre_op" ]; then
    say "✗ the repository changed since check; nothing staged"
    say "  expected operation $pre_op, found $active_op"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # Guard revset check:
  # roots(<upstream>..<source>):: ~ ::<source> ~ empty()
  local guard_revset="roots(${upstream_commit}..${source_commit}):: ~ ::${source_commit} ~ empty()"
  local guard_raw guard_rc=0
  # description.first_line() must never emit an empty middle
  # field here — IFS=$'\t' read below treats tab as IFS whitespace, so an
  # empty field is collapsed rather than kept, shifting every field after
  # it left by one (the parent's change ID lands in $desc, and $parents
  # comes out empty, misreporting the row as "outside the stack").
  guard_raw="$(jj --no-integrate-operation log -r "$guard_revset" --no-graph -T 'change_id.short(8) ++ "\t" ++ if(description, description.first_line(), "(no description set)") ++ "\t" ++ parents.map(|p| p.change_id().short(8)).join(" ") ++ "\n"' 2>&1)" || guard_rc=$?
  if [ "$guard_rc" -ne 0 ]; then
    if printf '%s' "$guard_raw" | grep -qi 'working copy is stale'; then
      say "✗ this workspace is stale; nothing staged"
      say "  $(printf '%s' "$guard_raw" | head -1)"
      say ""
      say "next         jj workspace update-stale"
    else
      say "✗ jj failed evaluating the guard revset: $guard_raw"
    fi
    exit 1
  fi

  # --no-integrate-operation always writes its own "left uncommitted"
  # notice to stderr, even on a plain, successful log read; strip that one
  # known, benign line before parsing rows (real errors already exited
  # above via guard_rc).
  local guard_revs
  guard_revs="$(printf '%s\n' "$guard_raw" | grep -vi 'operation left uncommitted because --no-integrate-operation was requested')"

  if [ -n "$guard_revs" ]; then
    local count
    count="$(printf '%s' "$guard_revs" | grep -c '' || true)"
    say "✗ $count $(plural_word "$count" change changes) outside the fork stack would be rewritten; nothing staged"
    while IFS=$'\t' read -r ch desc parents; do
      [ -z "$ch" ] && continue
      [ -z "$desc" ] && desc="(no description set)"
      local where_hangs
      if [ "$parents" = "$source_change_id" ]; then
        where_hangs="on top of $source_change_id"
      elif [ -n "$parents" ]; then
        where_hangs="a side commit off ${parents%% *}"
      else
        where_hangs="outside the stack"
      fi
      say "  $ch  $desc  ($where_hangs)"
    done <<< "$guard_revs"
    say ""
    say "next         commit it and move master onto it, or move it off the stack;"
    say "             then:"
    say "             rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # The guard read above is the first jj command
  # since check that doesn't --ignore-working-copy, so when @ IS the
  # source change itself (not a separate empty child), it's also the
  # first command that can snapshot an uncommitted file straight into
  # source_commit. Nothing moved OUTSIDE the fork stack, so the guard
  # above passes — but rebasing by the receipt's now-stale source_commit
  # would replay against a commit that's no longer live. Re-resolve the
  # source change's live commit and refuse if it moved.
  local live_source_commit
  live_source_commit="$(jj --no-integrate-operation log -r "$source_change_id" --no-graph -T 'commit_id.short(8)' 2>/dev/null)"
  if [ "$live_source_commit" != "$source_commit" ]; then
    say "✗ master was rewritten since check; nothing staged"
    say "  recorded $source_commit, now $live_source_commit"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  say "herdr-rbf upstream sync — stage"
  printf '  %-14s %s (%s)\n' "receipt" "$RUN_ID" "$phase"
  printf '  %-14s %s  %s %s\n' "source" "$source_ref" "$source_change_id" "$source_commit"
  printf '  %-14s %s  %s\n' "onto" "$upstream_ref" "$upstream_commit"
  say "⋯ staging the rebase as a detached operation"

  jj_logged --no-integrate-operation --ignore-immutable rebase -b "$source_commit" -d "$upstream_commit"
  local rebase_combined="$JJ_OUT"

  local new_staged_op
  new_staged_op="$(printf '%s\n' "$rebase_combined" | sed -n 's/.*Operation left uncommitted because --no-integrate-operation was requested: \([a-f0-9]*\).*/\1/p')"

  if [ -z "$new_staged_op" ]; then
    say "✗ staging rebase failed: could not obtain staged operation ID" >&2
    say "$rebase_combined" >&2
    exit 1
  fi

  # Re-read the active operation after the rebase before claiming it's
  # unchanged. --no-integrate-operation is documented not to move it, but
  # this command never asserts that without checking.
  local post_rebase_op
  post_rebase_op="$(jj --ignore-working-copy op log --no-graph --limit 1 -T 'id.short(12)' 2>/dev/null)"
  if [ "$post_rebase_op" != "$pre_op" ]; then
    say "✗ the active operation moved during staging; nothing to trust"
    say "  expected $pre_op, found $post_rebase_op"
    exit 1
  fi

  # Count replayed changes and conflicts in staged op
  local replayed_count
  replayed_count="$(jj --at-op "$new_staged_op" log -r "${upstream_commit}..heads(::${source_change_id})" --no-graph -T '"."' 2>/dev/null | wc -c | tr -d ' ')"

  # A genuinely empty fork stack never
  # reaches here (check's own "already current" guard catches that
  # earlier) — 0 replayed this late means the rebase ran against a
  # source_commit that silently stopped being live, the same symptom the
  # re-resolve above exists to catch. Refuse rather than record a staged
  # op that carries nothing.
  if [ "$replayed_count" -eq 0 ]; then
    say "✗ 0 changes replayed; nothing staged"
    say "  master was rewritten since check; rerun check for a fresh receipt"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  local conflicted_count
  conflicted_count="$(jj --at-op "$new_staged_op" log -r "conflicts() & ${upstream_commit}..heads(::${source_change_id})" --no-graph -T '"."' 2>/dev/null | wc -c | tr -d ' ')"

  local conflict_text
  if [ "$conflicted_count" -eq 0 ]; then
    conflict_text="no conflicts"
  elif [ "$conflicted_count" -eq 1 ]; then
    conflict_text="1 holds conflicts"
  else
    conflict_text="$conflicted_count hold conflicts"
  fi

  say "✓ staged operation $new_staged_op (before: $pre_op)"
  say "✓ $replayed_count $(plural_word "$replayed_count" change changes) replayed; $conflict_text"
  say "✓ active operation and this working copy unchanged; nothing integrated"
  say ""
  say "next         rbf/scripts/upstream-sync.sh inspect $RUN_ID"

  # Update receipt atomically
  local old_content
  old_content="$(grep -v '^phase=' "$RECEIPT_FILE" | grep -v '^staged_op=' | grep -v '^updated_at=')"
  local new_content
  new_content="$(cat <<REC
phase=staged-not-integrated
staged_op=$new_staged_op
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
$old_content
REC
)"
  write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
  log_msg "staged run_id=$RUN_ID staged_op=$new_staged_op replayed=$replayed_count conflicts=$conflicted_count"
}

# ---------------------------------------------------------------------------
# Phase 3: inspect
# ---------------------------------------------------------------------------

cmd_inspect() {
  local rec_arg="${1:-}"
  if [ -z "$rec_arg" ]; then
    say "Error: inspect requires a receipt argument." >&2
    exit 1
  fi
  resolve_receipt_file "$rec_arg"
  reconcile_receipt
  refuse_if_stale_workspace

  local phase staged_op upstream_commit source_change_id
  phase="$RECON_PHASE"
  staged_op="$(get_rec staged_op)"
  upstream_commit="$(get_rec upstream_commit)"
  source_change_id="$(get_rec source_change_id)"

  if [ -z "$staged_op" ]; then
    say "✗ staged operation not found; nothing inspected"
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # Refuse an unknown staged operation (not just an empty one). An
  # all-zero ID is jj's own root-of-the-op-log ID: it always resolves via
  # --at-op, but no real `stage` ever records it.
  if is_bogus_op_id "$staged_op" || ! jj --at-op "$staged_op" op log --no-graph --limit 1 -T 'id' >/dev/null 2>&1; then
    say "✗ staged operation not found; nothing inspected"
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  say "herdr-rbf upstream sync — inspect"
  printf '  %-14s %s (%s)\n' "receipt" "$RUN_ID" "$phase"
  printf '  %-14s %s\n' "operation" "$staged_op"
  say ""

  # File classification sets
  HOOKED_FILES="$(get_rec hooked_files | tr ',' '\n')"
  OWNED_FILES="$(get_rec owned_files | tr ',' '\n')"
  DELETED_FILES="$(get_rec deleted_files | tr ',' '\n')"

  say "conflicts each change adds"

  local staged_revs
  staged_revs="$(jj --at-op "$staged_op" log -r "${upstream_commit}..heads(::${source_change_id})" --no-graph --reversed -T 'change_id.short(8) ++ "\t" ++ description.first_line() ++ "\n"' 2>/dev/null || true)"

  local conflicted_changes=()
  local total_conflicted_changes=0
  local total_regions=0
  local upstream_regions=0
  local fork_owned_regions=0
  local unknown_regions=0

  # Per-change conflict calculation, via the shared own-conflicts rule
  while IFS=$'\t' read -r ch desc; do
    [ -z "$ch" ] && continue
    compute_own_conflicts "$staged_op" "$ch"
    [ "$OWN_CONFLICT_TOTAL" -eq 0 ] && continue

    local file_region_pairs=""
    while IFS= read -r pair; do
      [ -z "$pair" ] && continue
      if [ -n "$file_region_pairs" ]; then
        file_region_pairs="${file_region_pairs} · ${pair}"
      else
        file_region_pairs="$pair"
      fi
      local f cls
      f="${pair% *}"
      cls="$(classify_file "$f")"
      local reg="${pair##* }"
      case "$cls" in
        "upstream-file edit") upstream_regions=$((upstream_regions + reg)) ;;
        "fork-owned collision") fork_owned_regions=$((fork_owned_regions + reg)) ;;
        *) unknown_regions=$((unknown_regions + reg)) ;;
      esac
    done <<< "$OWN_CONFLICT_PAIRS"

    total_conflicted_changes=$((total_conflicted_changes + 1))
    total_regions=$((total_regions + OWN_CONFLICT_TOTAL))
    conflicted_changes+=("$ch"$'\t'"$desc"$'\t'"$OWN_CONFLICT_TOTAL"$'\t'"$file_region_pairs")
    # Log every ledger row, not just the ones the on-screen cap
    # shows — the real sync's own per-change counts come from this record.
    log_msg "ledger run_id=$RUN_ID phase=inspect change=$ch subject=\"$desc\" regions=$OWN_CONFLICT_TOTAL pairs=\"$file_region_pairs\""
  done <<< "$staged_revs"
  log_msg "ledger run_id=$RUN_ID phase=inspect total_changes=$total_conflicted_changes total_regions=$total_regions"

  if [ "$total_conflicted_changes" -eq 0 ]; then
    say "  none"
  else
    local shown_count=0
    local shown_regions=0
    for entry in "${conflicted_changes[@]}"; do
      if [ "$total_conflicted_changes" -gt 3 ] && [ "$shown_count" -ge 3 ]; then
        break
      fi
      local ch desc reg pairs
      ch="$(printf '%s' "$entry" | cut -f1)"
      desc="$(printf '%s' "$entry" | cut -f2)"
      reg="$(printf '%s' "$entry" | cut -f3)"
      pairs="$(printf '%s' "$entry" | cut -f4)"
      shown_count=$((shown_count + 1))
      shown_regions=$((shown_regions + reg))

      # Cut subjects to 49 chars + "…" so a row fits 80 columns, and pad
      # the field by characters, not bash 3.2's
      # byte-based printf '%-Ns' (which under-pads a multi-byte "…").
      local short_desc="$desc"
      if [ "${#desc}" -gt 49 ]; then
        short_desc="${desc:0:49}…"
      fi
      local reg_label
      reg_label="$(plural_word "$reg" region regions)"
      printf '  %-8s  ' "$ch"
      pad_chars "$short_desc" 50
      printf '   %d %s\n' "$reg" "$reg_label"
      printf '            %s\n' "$pairs"
    done

    if [ "$total_conflicted_changes" -gt 3 ]; then
      local more_changes=$((total_conflicted_changes - shown_count))
      local more_regions=$((total_regions - shown_regions))
      say "  ($more_changes more $(plural_word "$more_changes" change changes), $more_regions $(plural_word "$more_regions" region regions))"
    fi
    say "  classes    upstream-file edit $upstream_regions · fork-owned collision $fork_owned_regions · unknown $unknown_regions"
  fi
  say ""

  # Change map preview (carried / empty / missing), scoped to the range
  # between upstream and the source change (the same fix as finish's walk).
  local carried_count=0
  local empty_count=0
  local missing_count=0
  local change_rows
  change_rows="$(get_rec_all change)"
  local range="${upstream_commit}..heads(::${source_change_id})"

  while IFS=: read -r ch _commit desc; do
    [ -z "$ch" ] && continue
    local in_staged diff_len
    in_staged="$(jj --at-op "$staged_op" log -r "$ch & (${range})" --no-graph -T 'commit_id' 2>/dev/null || true)"
    if [ -z "$in_staged" ]; then
      missing_count=$((missing_count + 1))
    else
      diff_len="$(jj --at-op "$staged_op" diff -r "$ch" --summary 2>/dev/null | wc -c | tr -d ' ')"
      if [ "$diff_len" -eq 0 ]; then
        empty_count=$((empty_count + 1))
      else
        carried_count=$((carried_count + 1))
      fi
    fi
  done <<< "$change_rows"

  say "fork changes $carried_count carried · $empty_count empty · $missing_count missing"
  say ""
  # reconcile_receipt (above) can have already moved this receipt
  # past staged-not-integrated — point at what phase actually needs next,
  # not always integrate (which would then just refuse as already done).
  case "$phase" in
    integrated-conflicted)
      say "next         resolve the remaining conflicts, then rbf/scripts/upstream-sync.sh finish $RUN_ID"
      ;;
    integrated-clean)
      say "next         rbf/scripts/upstream-sync.sh finish $RUN_ID"
      ;;
    *)
      say "next         rbf/scripts/upstream-sync.sh integrate $RUN_ID"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Phase 4: integrate
# ---------------------------------------------------------------------------

cmd_integrate() {
  local rec_arg="${1:-}"
  if [ -z "$rec_arg" ]; then
    say "Error: integrate requires a receipt argument." >&2
    exit 1
  fi
  resolve_receipt_file "$rec_arg"
  reconcile_receipt
  refuse_if_stale_workspace

  local pre_op staged_op source_change_id upstream_commit
  pre_op="$(get_rec pre_op)"
  staged_op="$(get_rec staged_op)"
  source_change_id="$(get_rec source_change_id)"
  upstream_commit="$(get_rec upstream_commit)"

  if [ "$RECON_PHASE" != "staged-not-integrated" ]; then
    say "✗ already integrated (phase: $RECON_PHASE); nothing integrated again"
    if [ "$RECON_PHASE" = "integrated-conflicted" ]; then
      say "next         resolve the remaining conflicts, then rbf/scripts/upstream-sync.sh finish $RUN_ID"
    else
      say "next         rbf/scripts/upstream-sync.sh finish $RUN_ID"
    fi
    exit 1
  fi

  # Refuse an unknown staged operation.
  if [ -z "$staged_op" ] || is_bogus_op_id "$staged_op" || ! jj --at-op "$staged_op" op log --no-graph --limit 1 -T 'id' >/dev/null 2>&1; then
    say "✗ staged operation not found; nothing integrated"
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  local active_op active_rc=0
  active_op="$(jj op log --no-graph --limit 1 -T 'id.short(12)' 2>&1)" || active_rc=$?
  if [ "$active_rc" -ne 0 ]; then
    if printf '%s' "$active_op" | grep -qi 'working copy is stale'; then
      say "✗ this workspace is stale; nothing integrated"
      say "  $(printf '%s' "$active_op" | head -1)"
      say ""
      say "next         jj workspace update-stale"
    else
      say "✗ jj failed reading the active operation: $active_op"
    fi
    exit 1
  fi
  if [ "$active_op" != "$pre_op" ]; then
    say "✗ the repository changed since stage; nothing integrated"
    say "  expected operation $pre_op, found $active_op"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  say "⋯ integrating operation $staged_op"
  # Check jj op integrate's own exit status, never assume success.
  if ! jj_logged op integrate "$staged_op"; then
    say "✗ jj op integrate failed: $JJ_OUT"
    exit 1
  fi
  if ! jj_logged workspace update-stale; then
    say "✗ jj workspace update-stale failed: $JJ_OUT"
    exit 1
  fi

  # Master's own reporting falls back to the source change's
  # own head when "master" doesn't resolve yet (the master@origin source
  # mode, before any local master bookmark exists) — and says "recorded
  # tip", not "master", since nothing named master actually moved.
  local master_change master_commit has_local_master=1
  master_change="$(jj log -r master --no-graph -T 'change_id.short(8)' 2>/dev/null || true)"
  master_commit="$(jj log -r master --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ -z "$master_change" ]; then
    has_local_master=0
    master_change="$(jj log -r "heads(::${source_change_id})" --no-graph -T 'change_id.short(8)' 2>/dev/null || true)"
    master_commit="$(jj log -r "heads(::${source_change_id})" --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  fi

  if [ "$has_local_master" -eq 1 ]; then
    say "✓ integrated; master -> $master_change $master_commit, unverified until finish"
  else
    say "✓ integrated; recorded tip -> $master_change $master_commit, unverified until finish"
  fi

  # The conflict range is built from the receipt's upstream_commit and
  # source_change_id, never a hard-coded master@upstream..master — that
  # breaks under UPSTREAM_BRANCH=main and in the master@origin source mode.
  local range="${upstream_commit}..heads(::${source_change_id})"
  local conf_revs
  conf_revs="$(jj_guard log -r "conflicts() & (${range})" --no-graph --reversed -T 'change_id.short(8) ++ "\t" ++ description.first_line() ++ "\n"')" || exit 1
  local conf_count
  conf_count="$(printf '%s' "$conf_revs" | grep -c '' || true)"

  HOOKED_FILES="$(get_rec hooked_files | tr ',' '\n')"
  OWNED_FILES="$(get_rec owned_files | tr ',' '\n')"
  DELETED_FILES="$(get_rec deleted_files | tr ',' '\n')"

  local new_phase="integrated-clean"

  if [ "$conf_count" -gt 0 ]; then
    new_phase="integrated-conflicted"

    # Resolving the lowest change clears the
    # conflicts it caused above it, so a row for a change that only
    # inherits a conflict is noise — list and count only changes with
    # their OWN conflict regions (the ledger's own rule). Every row (not
    # just the ones shown on screen) is logged in full.
    #
    # Pass 1: find which changes have own conflicts at all, log every one
    # in full, and count them. Change IDs are fixed-width and never carry
    # a newline or tab, so a newline-joined list of them is safe to build
    # here — unlike OWN_CONFLICT_PAIRS/PATHS, which are themselves
    # multi-line and can't survive being packed into one delimited row.
    local own_conf_ids=""
    local own_conf_count=0
    while IFS=$'\t' read -r ch desc; do
      [ -z "$ch" ] && continue
      compute_own_conflicts "" "$ch"
      [ "$OWN_CONFLICT_TOTAL" -eq 0 ] && continue
      own_conf_count=$((own_conf_count + 1))
      own_conf_ids="${own_conf_ids}${ch}"$'\n'
      log_msg "ledger run_id=$RUN_ID phase=integrate change=$ch subject=\"$desc\" regions=$OWN_CONFLICT_TOTAL pairs=\"$(printf '%s' "$OWN_CONFLICT_PAIRS" | tr '\n' ';')\""
    done <<< "$conf_revs"

    say "✓ this workspace updated; $own_conf_count $(plural_word "$own_conf_count" 'change has' 'changes have') own conflicts, markers in their files"
    say "⚠ other workspaces are now stale; run jj workspace update-stale in each"
    say ""
    say "resolve bottom-up, one change at a time"

    # Pass 2: recompute each shown change's own paths (cheap: one change
    # at a time) to render its row — this is what actually reads them
    # correctly, since they're multi-line values.
    local idx=1
    local shown=0
    while IFS= read -r ch; do
      [ -z "$ch" ] && continue
      if [ "$own_conf_count" -gt 4 ] && [ "$shown" -ge 4 ]; then
        break
      fi
      compute_own_conflicts "" "$ch"

      local file_list=""
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ -n "$file_list" ]; then file_list="${file_list}, ${f}"; else file_list="$f"; fi
      done <<< "$OWN_CONFLICT_PATHS"

      # Flag the row if ANY of its own files is an unusual class, not
      # just whichever file the loop checked last.
      local extra_flag=""
      while IFS= read -r f; do
        [ -z "$f" ] && continue
        [ -n "$extra_flag" ] && continue
        local cls
        cls="$(classify_file "$f")"
        case "$cls" in
          "fork-owned collision") extra_flag="  ⚠ fork-owned: inspect by hand" ;;
          "deleted or renamed by fork") extra_flag="  ⚠ deleted or renamed by the fork" ;;
          "unknown") extra_flag="  ⚠ unknown: inspect by hand" ;;
        esac
      done <<< "$OWN_CONFLICT_PATHS"

      printf '   %-2d %-8s  %s%s\n' "$idx" "$ch" "$file_list" "$extra_flag"
      idx=$((idx + 1))
      shown=$((shown + 1))
    done <<< "$own_conf_ids"

    if [ "$own_conf_count" -gt 4 ]; then
      local more=$((own_conf_count - shown))
      say "      ($more more)"
    fi

    say "for each     jj new <change>"
    say "             edit the files: upstream's code, with the fork's change on top"
    say "             jj squash --from '<change>..@' --into <change>"
    say "then         jj new master"
    say "next         rbf/scripts/upstream-sync.sh finish $RUN_ID"
  else
    say "✓ this workspace updated; no conflicts"
    say "⚠ other workspaces are now stale; run jj workspace update-stale in each"
    say "next         rbf/scripts/upstream-sync.sh finish $RUN_ID"
  fi

  # Update receipt atomically
  local old_content
  old_content="$(grep -v '^phase=' "$RECEIPT_FILE" | grep -v '^updated_at=')"
  local new_content
  new_content="$(cat <<REC
phase=$new_phase
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
$old_content
REC
)"
  write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
  log_msg "integrated run_id=$RUN_ID phase=$new_phase"
}

# ---------------------------------------------------------------------------
# Phase 5: finish
# ---------------------------------------------------------------------------

cmd_finish() {
  local rec_arg=""
  local cli_verify_cmd=""
  local dropped_changes=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --verify-cmd)
        [ $# -lt 2 ] && { say "Error: --verify-cmd requires a value." >&2; exit 1; }
        cli_verify_cmd="$2"
        shift 2
        ;;
      --dropped)
        [ $# -lt 2 ] && { say "Error: --dropped requires a value." >&2; exit 1; }
        dropped_changes+=("$2")
        shift 2
        ;;
      --skip-verify)
        say "Error: unknown option: --skip-verify" >&2
        usage >&2
        exit 1
        ;;
      --log-path)
        [ $# -lt 2 ] && { say "Error: --log-path requires a value." >&2; exit 1; }
        LOG="$2"
        shift 2
        ;;
      -*)
        say "Error: unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
      *)
        if [ -z "$rec_arg" ]; then
          rec_arg="$1"
          shift
        else
          say "Error: unexpected argument: $1" >&2
          exit 1
        fi
        ;;
    esac
  done

  if [ -z "$rec_arg" ]; then
    say "Error: finish requires a receipt argument." >&2
    exit 1
  fi
  resolve_receipt_file "$rec_arg"
  reconcile_receipt
  refuse_if_stale_workspace

  local phase pre_op source_change_id upstream_commit origin_commit
  phase="$RECON_PHASE"
  pre_op="$(get_rec pre_op)"
  source_change_id="$(get_rec source_change_id)"
  upstream_commit="$(get_rec upstream_commit)"
  origin_commit="$(get_rec origin_commit)"
  local range="${upstream_commit}..heads(::${source_change_id})"

  # Finish only ever verifies an integrated receipt. Repeating an
  # already-verified receipt is a harmless, idempotent re-check.
  case "$phase" in
    integrated-clean|integrated-conflicted|verified-local-master) ;;
    *)
      say "✗ receipt is not yet integrated (phase: $phase); not verified, nothing run"
      if [ -n "$(get_rec staged_op)" ]; then
        say "next         rbf/scripts/upstream-sync.sh integrate $RUN_ID"
      else
        say "next         rbf/scripts/upstream-sync.sh stage $RUN_ID"
      fi
      exit 1
      ;;
  esac

  # In the master@origin source mode (no local
  # master existed at check time), integrate carries the rebase but writes
  # no local bookmark, so there's nothing for finish to verify as "local
  # master" yet. Refuse with the exact recovery, rather than a generic
  # jj-doesn't-exist error. A CONFLICTED master is a distinct
  # case from "doesn't exist" (master itself can go conflicted
  # between check and finish, e.g. via a push to origin then a fetch) — it
  # falls through here so the jj_guard call below reports and stops on it,
  # rather than this printing the wrong "no local master" diagnosis.
  local master_probe_out master_probe_rc=0
  master_probe_out="$(jj log -r master --no-graph -T 'commit_id' 2>&1)" || master_probe_rc=$?
  if [ "$master_probe_rc" -ne 0 ] && ! printf '%s' "$master_probe_out" | grep -qi 'is conflicted'; then
    say "✗ no local master; not verified, nothing run"
    say "fix once     jj bookmark set master -r $source_change_id"
    say "next         jj new master"
    exit 1
  fi

  # Master must still be the rebased successor of the recorded
  # source change (matched by change ID), never a repo-wide assumption.
  # A CONFLICTED master (multiple targets) is a distinct case
  # from "doesn't exist" and must refuse here too, not silently compare
  # against an empty value.
  local master_change
  master_change="$(jj_guard log -r master --no-graph -T 'change_id.short(8)')" || exit 1
  if [ "$master_change" != "$source_change_id" ]; then
    say "✗ master is not the recorded stack tip; not verified, nothing run"
    say "  master is $master_change, the recorded source change is $source_change_id"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # 1. Conflicts check, scoped to the receipt's own range.
  local remaining_conflicts
  remaining_conflicts="$(jj_guard log -r "conflicts() & (${range})" --no-graph -T 'change_id.short(8) ++ "\n"')" || exit 1
  if [ -n "$remaining_conflicts" ]; then
    say "✗ conflicts remain in the fork stack; not verified, nothing run"
    printf '%s\n' "$remaining_conflicts" | while IFS= read -r c; do
      [ -n "$c" ] && say "  $c"
    done
    exit 1
  fi

  # 2. Checkout (@) check: finish only verifies master's own tree, so the
  # checkout must be master itself, or an empty child of it.
  local at_diff at_parents
  at_parents="$(jj log -r '@' --no-graph -T 'parents.map(|p| p.change_id().short(8)).join(" ")' 2>/dev/null)"
  local master_commit
  master_commit="$(jj log -r master --no-graph -T 'commit_id.short(8)' 2>/dev/null)"
  local at_change
  at_change="$(jj log -r '@' --no-graph -T 'change_id.short(8)' 2>/dev/null)"

  local checkout_status=""
  if [ "$at_change" = "$master_change" ]; then
    checkout_status="@ is master"
  elif [ "$at_parents" = "$master_change" ]; then
    at_diff="$(jj diff -r '@' --summary 2>/dev/null | wc -c | tr -d ' ')"
    if [ "$at_diff" -eq 0 ]; then
      checkout_status="@ is an empty child of master"
    fi
  fi

  if [ -z "$checkout_status" ]; then
    say "✗ @ is not master; not verified, nothing run"
    say "  finish verifies master's tree from a checkout that is master"
    say ""
    say "next         jj new master"
    exit 1
  fi

  # 3. Change map walk, scoped to the recorded range: a change moved
  # outside the stack still "exists" in the repo, but it's
  # no longer part of what master carries.
  local change_rows
  change_rows="$(get_rec_all change)"
  local all_change_ids
  all_change_ids="$(printf '%s\n' "$change_rows" | cut -d: -f1)"
  local existing_dropped
  existing_dropped="$(get_rec_all dropped | awk '{print $1}' | tr '\n' ' ' | xargs)"

  local carried_changes=()
  local empty_changes=()
  local missing_changes=()
  local total_fork_changes=0

  while IFS=: read -r ch _commit desc; do
    [ -z "$ch" ] && continue
    total_fork_changes=$((total_fork_changes + 1))
    local in_master
    in_master="$(jj log -r "$ch & (${range})" --no-graph -T 'commit_id' 2>/dev/null || true)"
    if [ -z "$in_master" ]; then
      if printf ' %s ' "$existing_dropped" | grep -Fq " $ch "; then
        :
      else
        missing_changes+=("$ch"$'\t'"$desc")
      fi
    else
      local diff_len
      diff_len="$(jj diff -r "$ch" --summary 2>/dev/null | wc -c | tr -d ' ')"
      if [ "$diff_len" -eq 0 ]; then
        empty_changes+=("$ch"$'\t'"$desc")
      else
        carried_changes+=("$ch")
      fi
    fi
  done <<< "$change_rows"

  # Validate every --dropped ID against the change map computed above,
  # BEFORE recording anything. Refuse an ID that's still carried, or isn't
  # a fork change in this receipt at all. An ID already recorded as
  # dropped in an earlier run is a harmless no-op.
  local new_drops=()
  local d
  # Bash 3.2: "${arr[@]}" on a declared-but-empty array raises "unbound
  # variable" under set -u, so every array iteration here is guarded by
  # its own length check first.
  if [ "${#dropped_changes[@]}" -gt 0 ]; then
    for d in "${dropped_changes[@]}"; do
      if ! printf '%s\n' "$all_change_ids" | grep -Fxq "$d"; then
        say "✗ $d is not a fork change in this receipt; nothing dropped, nothing run"
        exit 1
      fi
      if printf ' %s ' "$existing_dropped" | grep -Fq " $d "; then
        continue
      fi
      local is_missing=0
      local m m_ch
      if [ "${#missing_changes[@]}" -gt 0 ]; then
        for m in "${missing_changes[@]}"; do
          m_ch="$(printf '%s' "$m" | cut -f1)"
          [ "$m_ch" = "$d" ] && is_missing=1 && break
        done
      fi
      if [ "$is_missing" -ne 1 ]; then
        say "✗ $d is still carried; it can't be dropped; nothing dropped, nothing run"
        exit 1
      fi
      new_drops+=("$d")
    done
  fi

  # Every guard above this point has passed: record the new drops
  # atomically now, before verification runs, so the decision to drop a
  # change survives even if the verify command fails.
  if [ "${#new_drops[@]}" -gt 0 ]; then
    local dropped_lines=""
    local nd drop_ts
    drop_ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    for nd in "${new_drops[@]}"; do
      dropped_lines="${dropped_lines}dropped=$nd $drop_ts"$'\n'
    done
    local rest_content
    rest_content="$(grep -v '^updated_at=' "$RECEIPT_FILE")"
    local new_content
    new_content="$(cat <<REC
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
${dropped_lines}${rest_content}
REC
)"
    write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
    log_msg "dropped run_id=$RUN_ID ids=${new_drops[*]}"

    # Recompute missing_changes, excluding the changes just dropped.
    local recomputed_missing=()
    local mm mm_ch was_dropped
    if [ "${#missing_changes[@]}" -gt 0 ]; then
      for mm in "${missing_changes[@]}"; do
        mm_ch="$(printf '%s' "$mm" | cut -f1)"
        was_dropped=0
        for nd in "${new_drops[@]}"; do
          [ "$mm_ch" = "$nd" ] && was_dropped=1 && break
        done
        [ "$was_dropped" -eq 0 ] && recomputed_missing+=("$mm")
      done
    fi
    if [ "${#recomputed_missing[@]}" -gt 0 ]; then
      missing_changes=("${recomputed_missing[@]}")
    else
      missing_changes=()
    fi
  fi

  if [ "${#missing_changes[@]}" -gt 0 ]; then
    local m_count="${#missing_changes[@]}"
    say "✗ $m_count fork $(plural_word "$m_count" 'change is' 'changes are') missing; not verified, nothing run"
    local first_missing=""
    for m in "${missing_changes[@]}"; do
      local m_ch2 m_desc
      m_ch2="$(printf '%s' "$m" | cut -f1)"
      m_desc="$(printf '%s' "$m" | cut -f2)"
      say "  $m_ch2  $m_desc"
      [ -z "$first_missing" ] && first_missing="$m_ch2"
    done
    local empty_str="none"
    if [ "${#empty_changes[@]}" -gt 0 ]; then
      empty_str="$(for e in "${empty_changes[@]}"; do printf '%s ' "$(printf '%s' "$e" | cut -f1)"; done | xargs | tr ' ' ',')"
    fi
    local all_dropped_now
    all_dropped_now="$(get_rec_all dropped | awk '{print $1}' | tr '\n' ' ' | xargs)"
    local dropped_str="none"
    if [ -n "$all_dropped_now" ]; then
      dropped_str="$(printf '%s' "$all_dropped_now" | tr ' ' ',')"
    fi
    say "  empty: $empty_str; dropped: $dropped_str"
    say ""
    say "next         bring it back from jj op log, or record a deliberate drop:"
    say "             rbf/scripts/upstream-sync.sh finish $RUN_ID --dropped $first_missing"
    exit 1
  fi

  # 4. Verify command resolution. Never read from the receipt — a receipt
  # is written by `check`, and trusting a command string from it would let
  # anyone who can write a receipt run arbitrary code via `finish`. Only
  # --verify-cmd or UPSTREAM_SYNC_VERIFY_CMD, both supplied fresh by the
  # caller of `finish` itself.
  local verify_to_run="${cli_verify_cmd:-$VERIFY_CMD}"
  if [ -z "$verify_to_run" ]; then
    say "✗ no verify command configured; not verified, nothing run"
    say "next         pass --verify-cmd <cmd> or set UPSTREAM_SYNC_VERIFY_CMD"
    exit 1
  fi

  say "herdr-rbf upstream sync — finish"
  printf '  %-14s %s (%s)\n' "receipt" "$RUN_ID" "$phase"
  printf '  %-14s %s\n' "checkout" "$checkout_status"
  printf '  %-14s %s\n' "verify" "$verify_to_run"

  local empty_str="none"
  if [ "${#empty_changes[@]}" -gt 0 ]; then
    empty_str="$(for e in "${empty_changes[@]}"; do printf '%s ' "$(printf '%s' "$e" | cut -f1)"; done | xargs | tr ' ' ',')"
  fi
  local all_dropped_final
  all_dropped_final="$(get_rec_all dropped | awk '{print $1}' | tr '\n' ' ' | xargs)"
  local dropped_str="none"
  if [ -n "$all_dropped_final" ]; then
    dropped_str="$(printf '%s' "$all_dropped_final" | tr ' ' ',')"
  fi

  say "✓ carried ${#carried_changes[@]} of $total_fork_changes fork changes; empty: $empty_str; missing: none; dropped: $dropped_str"

  if [ "${#empty_changes[@]}" -gt 0 ]; then
    local e_count="${#empty_changes[@]}"
    say "⚠ $e_count fork $(plural_word "$e_count" 'change is' 'changes are') now empty; upstream already has it, or its side was lost"
    for e in "${empty_changes[@]}"; do
      local e_ch e_desc
      e_ch="$(printf '%s' "$e" | cut -f1)"
      e_desc="$(printf '%s' "$e" | cut -f2)"
      # Cut at 61 chars + "…" so the row fits 80 columns.
      if [ "${#e_desc}" -gt 61 ]; then
        e_desc="${e_desc:0:61}…"
      fi
      say "  $e_ch  $e_desc"
    done
  fi

  # master@origin is re-read and compared to what check recorded,
  # both before and after verifying — it must still match the receipt.
  local origin_before
  origin_before="$(jj log -r master@origin --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ -n "$origin_commit" ] && [ "$origin_before" != "$origin_commit" ]; then
    say "✗ master@origin moved since check; not verified, nothing run"
    say "  recorded $origin_commit, now $origin_before"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  # The upstream tip is compared before AND after
  # the verify command, not just after — a race that moved it before
  # verifying even started should fail fast with its own message, not
  # get misdiagnosed as "moved during verification".
  local upstream_before
  upstream_before="$(jj log -r "${UPSTREAM_BRANCH}@upstream" --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ "$upstream_before" != "$upstream_commit" ]; then
    say "✗ the upstream tip moved since check; not verified, nothing run"
    say "  recorded $upstream_commit, now $upstream_before"
    say ""
    say "next         rbf/scripts/upstream-sync.sh check"
    exit 1
  fi

  say "⋯ verifying"

  # Stream verification command; jj's own output stays in the log, but the
  # verify command's is the user's own and passes straight through.
  local v_rc=0
  bash -c "$verify_to_run" || v_rc=$?

  if [ "$v_rc" -ne 0 ]; then
    say "✗ verification failed (exit $v_rc); not verified, receipt unchanged"
    say "  master still names the unverified candidate $master_change $master_commit"
    say ""
    say "next         fix it in the change that broke, then run finish again"
    say "abandon      jj op restore $pre_op"
    say "             only if jj op log shows no unrelated operation since"
    log_msg "finish failed verify_rc=$v_rc"
    exit "$v_rc"
  fi

  local origin_after
  origin_after="$(jj log -r master@origin --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ -n "$origin_commit" ] && [ "$origin_after" != "$origin_commit" ]; then
    say "✗ master@origin moved during verification; not verified, receipt unchanged"
    say "  recorded $origin_commit, now $origin_after"
    log_msg "finish failed origin moved during verify"
    exit 1
  fi

  # The verify command runs arbitrary user code, which can
  # move master itself or advance the upstream tip (a background rebase,
  # a hook that fetches). Re-read both and refuse rather than stamp
  # verified-local-master onto a candidate that isn't the one just run.
  local master_change_after master_commit_after upstream_after
  master_change_after="$(jj log -r master --no-graph -T 'change_id.short(8)' 2>/dev/null || true)"
  master_commit_after="$(jj log -r master --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  upstream_after="$(jj log -r "${UPSTREAM_BRANCH}@upstream" --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
  if [ "$master_change_after" != "$master_change" ] || [ "$master_commit_after" != "$master_commit" ] || [ "$upstream_after" != "$upstream_commit" ]; then
    say "✗ master or the upstream tip moved during verification; not verified, receipt unchanged"
    say "  master was $master_change $master_commit, now $master_change_after $master_commit_after"
    say "  upstream was $upstream_commit, now $upstream_after"
    log_msg "finish failed master or upstream moved during verify"
    exit 1
  fi

  say "✓ verification passed"

  # Print moved bookmarks
  local recorded_bms
  recorded_bms="$(get_rec bookmarks | tr ',' '\n')"
  while IFS=: read -r b_name b_was; do
    [ -z "$b_name" ] && continue
    local b_now b_ch
    b_now="$(jj log -r "$b_name" --no-graph -T 'commit_id.short(8)' 2>/dev/null || true)"
    b_ch="$(jj log -r "$b_name" --no-graph -T 'change_id.short(8)' 2>/dev/null || true)"
    if [ -n "$b_now" ]; then
      say "✓ $b_name -> $b_ch $b_now (was $b_was)"
    fi
  done <<< "$recorded_bms"

  say ""
  say "✓ verified local master; master@origin unchanged at $origin_after"
  say "not done     push, install, release, upstream PR"
  if [ "${#empty_changes[@]}" -gt 0 ]; then
    say "check        each empty change: jj diff -r <change> against upstream's"
  fi

  # Update receipt. Record the verify command that ran (never the
  # source of one — finish never reads verify_cmd= back).
  local old_content
  old_content="$(grep -v '^phase=' "$RECEIPT_FILE" | grep -v '^updated_at=' | grep -v '^verify_result=' | grep -v '^verified_tip_commit=' | grep -v '^verify_cmd=')"
  local new_content
  new_content="$(cat <<REC
phase=verified-local-master
verify_result=passed
verify_cmd=$verify_to_run
verified_tip_commit=$master_commit
updated_at=$(date '+%Y-%m-%dT%H:%M:%S%z')
$old_content
REC
)"
  write_receipt_atomic "$RECEIPT_FILE" "$new_content" || exit 1
  log_msg "finish verified run_id=$RUN_ID master=$master_commit"
}

# ---------------------------------------------------------------------------
# Main Router
# ---------------------------------------------------------------------------

# --help needs neither jj nor a jj repo — parse it before repo
# discovery (below) so it still works outside one. Stops scanning at the
# first command word, same as the real option loop's own `break`, so
# this never changes what counts as a global option.
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    check|stage|inspect|integrate|finish)
      break
      ;;
  esac
done

if ! command -v jj >/dev/null 2>&1; then
  say "Error: jj (Jujutsu) is not installed or not in PATH." >&2
  exit 1
fi

REPO="$(jj root 2>/dev/null)" || {
  say "Error: not inside a jj repository." >&2
  exit 1
}
cd "$REPO" || exit 1

# Global option parsing
CMD="check"

while [ $# -gt 0 ]; do
  case "$1" in
    --log-path)
      [ $# -lt 2 ] && { say "Error: --log-path requires a value." >&2; exit 1; }
      LOG="$2"
      shift 2
      ;;
    --check-only)
      CMD="check"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    check|stage|inspect|integrate|finish)
      CMD="$1"
      shift
      break
      ;;
    -*)
      say "Error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
    *)
      say "Error: unknown command: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

case "$CMD" in
  check)
    cmd_check "$@"
    ;;
  stage)
    cmd_stage "$@"
    ;;
  inspect)
    cmd_inspect "$@"
    ;;
  integrate)
    cmd_integrate "$@"
    ;;
  finish)
    cmd_finish "$@"
    ;;
  *)
    say "Error: unknown command: $CMD" >&2
    usage >&2
    exit 1
    ;;
esac
