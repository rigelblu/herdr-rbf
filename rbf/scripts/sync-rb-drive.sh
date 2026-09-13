#!/usr/bin/env bash

# Mirror this project's rb-drive into a private remote backup (.rb-drive-remote/)
# with rsync — a faithful, secrets-and-all copy for safekeeping, not for sharing.
# The destination must be a pre-created symlink to your backup location (e.g. a
# Google Drive folder) so the mirror actually leaves the machine.
#
# For a fork you also publish, use sync-rb-drive-public.sh (secrets excluded).

set -euo pipefail

# Walk up from the script to the product root — the first ancestor holding rb-drive.
# This works at any nesting depth, so the script needs no per-project path tweaks.
find_product_root() {
  local dir="$1"
  while :; do
    [ -e "$dir/rb-drive" ] && { printf '%s\n' "$dir"; return 0; }
    [ "$dir" = "/" ] && return 1
    dir="$(dirname "$dir")"
  done
}

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
product_root="$(find_product_root "$script_dir")" \
  || { echo "error: no rb-drive found in any directory above $script_dir" >&2; exit 1; }
cd "$product_root"

# Cap how many files a single mirror may delete, as a backstop against a runaway
# --delete. Raise it for a legitimately large cleanup: RB_DRIVE_MAX_DELETE=500 ...
max_delete="${RB_DRIVE_MAX_DELETE:-100}"

usage() {
  cat <<'USAGE'
Usage: rbf/scripts/sync-rb-drive.sh [--dry-run]

Mirror rb-drive into .rb-drive-remote/rb-drive/ (a faithful private backup) with rsync.

Options:
  -n, --dry-run  Show what rsync would change, without writing or deleting.
  -h, --help     Show this help.

Environment:
  RB_DRIVE_MAX_DELETE  Max files the mirror may delete (default: 100).
USAGE
}

fail() {
  echo "error: $*" >&2
  exit 1
}

dry_run=false
for arg in "$@"; do
  case "$arg" in
    -n|--dry-run) dry_run=true ;;
    -h|--help) usage; exit 0 ;;
    *) fail "unknown argument: $arg" ;;
  esac
done

# A real rb-drive store always contains projects/. Without this guard an empty or
# half-built source (e.g. a freshly re-created symlink before data syncs back) would
# make rsync --delete wipe the entire destination backup.
[ -d "${product_root}/rb-drive/projects" ] \
  || fail "rb-drive/projects not found — refusing to mirror a missing or empty source with --delete"

# -L dereferences symlinks so the backup holds real files; --delete mirrors the source
# exactly; --max-delete is the runaway-deletion backstop to the sentinel above.
# The array stays non-empty so "${rsync_opts[@]}" is safe under set -u on bash 3.2.
rsync_opts=(-avL --delete "--max-delete=${max_delete}")
if [ "$dry_run" = true ]; then
  rsync_opts+=(--dry-run)
fi

# No trailing slash on src: rsync copies the rb-drive directory itself, so the private
# backup nests as <dest>/rb-drive/ — a faithful, low-churn mirror of the store.
dest="${product_root}/.rb-drive-remote/"
src="${product_root}/rb-drive"

# Require the destination to be a pre-created symlink (to the backup folder); otherwise
# rsync would silently mirror into a local, gitignored dir that never reaches the backup.
[ -L "${dest%/}" ] || fail "${dest%/} is not a symlink — point it at your backup folder before syncing"

rsync "${rsync_opts[@]}" "$src" "$dest"
