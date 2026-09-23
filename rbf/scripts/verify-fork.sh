#!/bin/bash

# The fork's full verify command. Runs the fork's own harnesses alongside
# upstream's, in order:
#   1. just ci                            (upstream's lint + tests)
#   2. just docs-contract-test            (upstream's docs contract)
#   3. rbf/scripts/upstream-sync.test.sh  (this fork's sync workflow harness)
#   4. every rbf/scripts/install-rbf.test.sh case except real-agent
#
# `real-agent` needs a logged-in `claude` first on PATH, so it stays a
# by-hand check; every other install-rbf.test.sh case is discovered from
# that script's own usage line, so this list never drifts out of sync.
#
# Builds the release binary once before the install-rbf cases, then runs
# them with RBF_TEST_SKIP_BUILD=1 so each case doesn't rebuild it. tag.gpgsign
# is off for the whole run (an ephemeral GIT_CONFIG override, no file
# touched): a test repo that inherits a signing config can hang or fail.
#
# Needs RBF_TEST_ROOT or EXTERNAL_DRIVE, for the harnesses' scratch root.
# Stops at the first failure and says which step failed.
#
# This is the fork's `--verify-cmd` for
# `rbf/scripts/upstream-sync.sh finish`, so it always runs from inside a
# herdr session. Clear every
# inherited HERDR_* variable first — otherwise `just ci`'s own spawned test
# server inherits this outer session's variables and
# pane_spawn_cwd_fallback_in_server fails. install-rbf.test.sh already
# strips them per case; this does the same for the whole run.
#
# Bash 3.2 compatible.

set -uo pipefail

for _herdr_var in $(compgen -v HERDR_ 2>/dev/null || env | sed -n 's/^\(HERDR_[A-Za-z0-9_]*\)=.*/\1/p'); do
  unset "$_herdr_var"
done

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 1

say() { printf '%s\n' "$*"; }

fail_step() {
  say "✗ $1 failed; stopping"
  exit 1
}

if [ -z "${RBF_TEST_ROOT:-}" ] && [ -z "${EXTERNAL_DRIVE:-}" ]; then
  say "✗ no scratch root; set RBF_TEST_ROOT or EXTERNAL_DRIVE"
  exit 1
fi

# tag.gpgsign off for the run: an ephemeral override via GIT_CONFIG_*, never
# written to any git config file, and undone automatically when this process
# and its children exit.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="tag.gpgsign"
export GIT_CONFIG_VALUE_0="false"

say "⋯ running just ci"
if ! just ci; then
  fail_step "just ci"
fi
say "✓ just ci passed"

say "⋯ running just docs-contract-test"
if ! just docs-contract-test; then
  fail_step "just docs-contract-test"
fi
say "✓ just docs-contract-test passed"

say "⋯ running rbf/scripts/upstream-sync.test.sh"
if ! bash rbf/scripts/upstream-sync.test.sh; then
  fail_step "rbf/scripts/upstream-sync.test.sh"
fi
say "✓ rbf/scripts/upstream-sync.test.sh passed"

say "⋯ building the release binary once for the install-rbf harness"
if ! cargo build --release --locked; then
  fail_step "cargo build --release --locked"
fi
say "✓ release binary built"

# Discover install-rbf.test.sh's own case list from its usage line, rather
# than hardcoding it here, so this never drifts if that list changes.
install_test="rbf/scripts/install-rbf.test.sh"
usage_line="$(bash "$install_test" __verify_fork_unknown_case__ 2>&1 >/dev/null | grep '^usage:' || true)"
cases_raw="$(printf '%s' "$usage_line" | sed -n 's/.*<\(.*\)>.*/\1/p')"
if [ -z "$cases_raw" ]; then
  say "✗ could not discover $install_test's case list from its usage line"
  exit 1
fi

old_ifs="$IFS"
IFS='|'
# shellcheck disable=SC2086 # word-splitting on $cases_raw is intentional here
set -- $cases_raw
IFS="$old_ifs"

for c in "$@"; do
  if [ "$c" = "real-agent" ]; then
    continue
  fi
  say "⋯ running $install_test $c"
  if ! RBF_TEST_SKIP_BUILD=1 bash "$install_test" "$c"; then
    fail_step "$install_test $c"
  fi
  say "✓ $install_test $c passed"
done

say ""
say "✓ verify-fork passed: just ci, just docs-contract-test, upstream-sync harness, install-rbf harness (every case but real-agent)"
