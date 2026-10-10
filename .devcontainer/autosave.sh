#!/usr/bin/env bash
# Automatically push the current work state (including untracked files)
# to `wip/<branch name>` at regular intervals.
#
# Env vars:
#   AUTOSAVE_INTERVAL      seconds between snapshots (default: 300)
#   AUTOSAVE_EXCLUDE_FILE  gitignore-format exclude file
#                          (default: <repo>/.devcontainer/autosave.ignore)
#   AUTOSAVE_ONCE          1 = take a single snapshot and exit (for tests)
INTERVAL="${AUTOSAVE_INTERVAL:-300}"   # seconds
REPO_DIR="${1:-$(pwd)}"
LAST_TREE=""

cd "$REPO_DIR" || exit 1
REPO_DIR="$(pwd)"

EXCLUDE_FILE="${AUTOSAVE_EXCLUDE_FILE:-$REPO_DIR/.devcontainer/autosave.ignore}"
case "$EXCLUDE_FILE" in
  /*) ;;                                   # absolute path
  *)  EXCLUDE_FILE="$REPO_DIR/$EXCLUDE_FILE" ;;
esac

snapshot_tree() {
  # Build a tree of all files using a temporary index (the real index is untouched).
  # The exclude file is re-read on every run, so edits take effect without restart.
  local tmp tree opts=()
  [ -f "$EXCLUDE_FILE" ] && opts=(-c "core.excludesFile=$EXCLUDE_FILE")

  tmp=$(mktemp -u) || return 1
  cp "$(git rev-parse --git-path index)" "$tmp" 2>/dev/null
  tree=$(GIT_INDEX_FILE="$tmp" git "${opts[@]}" add -A >/dev/null 2>&1 \
         && GIT_INDEX_FILE="$tmp" git write-tree)
  rm -f "$tmp"
  [ -n "$tree" ] && echo "$tree"
}

# Returns 0 when nothing needed to be done or the push succeeded, 1 when the push failed.
run_once() {
  local branch head_sha tree sha

  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  [ "$branch" = "HEAD" ] && return 0                # detached HEAD is excluded
  head_sha=$(git rev-parse HEAD 2>/dev/null) || return 0

  tree=$(snapshot_tree) || return 0
  [ "$tree" = "$LAST_TREE" ] && return 0            # skip if same as last time

  if [ "$tree" = "$(git rev-parse 'HEAD^{tree}')" ]; then
    sha="$head_sha"                                 # no changes: push HEAD as-is
  else
    sha=$(git -c user.name=autosave -c user.email=autosave@localhost \
          commit-tree "$tree" -p "$head_sha" -m "autosave: $(date -Is)") || return 0
  fi

  if git push origin "$sha:refs/heads/wip/$branch" --force --quiet 2>/dev/null; then
    LAST_TREE="$tree"
    return 0
  fi
  return 1
}

[ -f "$EXCLUDE_FILE" ] || echo "[autosave] exclude file not found: $EXCLUDE_FILE (only .gitignore is applied)" >&2

if [ "${AUTOSAVE_ONCE:-0}" = "1" ]; then
  run_once
  exit $?
fi

while true; do
  sleep "$INTERVAL"
  run_once || true
done