#!/bin/zsh
set -euo pipefail

SOURCE_ROOT="$(cd "$(dirname "$0")" && pwd)"
PUBLIC_REPO="${PUBLIC_REPO:-$HOME/Git/xtool-f1}"
COMMIT_MESSAGE="Sync latest iOS app source"

usage() {
  cat <<EOF
Usage: ./push-github-ios.sh [commit message]

Copies this repo's source-controlled working tree files into:
  $PUBLIC_REPO/iOS

Then stages iOS/, creates one Git commit, and pushes it.

Environment:
  PUBLIC_REPO  Public Git checkout path (default: $PUBLIC_REPO)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

(($#)) && COMMIT_MESSAGE="$*"

fail() {
  echo "push-github-ios.sh: $*" >&2
  exit 1
}

command -v sc >/dev/null || fail "sc is not available"
command -v git >/dev/null || fail "git is not available"
command -v rsync >/dev/null || fail "rsync is not available"

[[ -d "$SOURCE_ROOT/.source-control" ]] || fail "source repo is missing .source-control"
[[ -d "$PUBLIC_REPO/.git" ]] || fail "public Git repo not found: $PUBLIC_REPO"

PUBLIC_REPO="$(cd "$PUBLIC_REPO" && pwd)"
DEST="$PUBLIC_REPO/iOS"
GIT_ROOT="$(git -C "$PUBLIC_REPO" rev-parse --show-toplevel)"
GIT_ROOT="$(cd "$GIT_ROOT" && pwd)"

[[ "$GIT_ROOT" == "$PUBLIC_REPO" ]] || fail "public repo path is not the Git root: $PUBLIC_REPO"
[[ "$PUBLIC_REPO" != "$SOURCE_ROOT" ]] || fail "source and public repos must be different"
[[ ! -L "$DEST" ]] || fail "refusing to overwrite symlink: $DEST"
[[ ! -e "$DEST" || -d "$DEST" ]] || fail "iOS target is not a directory: $DEST"

git -C "$PUBLIC_REPO" diff --cached --quiet ||
  fail "public repo has pre-existing staged changes; commit or unstage them first"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT
FILE_LIST="$TMPDIR/tracked-files.txt"

(cd "$SOURCE_ROOT" && sc ls --tracked) | sed -n 's/^tracked: //p' > "$FILE_LIST"
[[ -s "$FILE_LIST" ]] || fail "no source-controlled files found"

while IFS= read -r tracked_path; do
  [[ "$tracked_path" != /* && "$tracked_path" != ../* && "$tracked_path" != *"/../"* ]] ||
    fail "unsafe tracked path: $tracked_path"
done < "$FILE_LIST"

mkdir -p "$DEST"
find "$DEST" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
rsync -a --files-from="$FILE_LIST" "$SOURCE_ROOT/" "$DEST/"

git -C "$PUBLIC_REPO" add -A iOS

if git -C "$PUBLIC_REPO" diff --cached --quiet -- iOS; then
  echo "No iOS changes to commit."
  exit 0
fi

git -C "$PUBLIC_REPO" commit -m "$COMMIT_MESSAGE"
git -C "$PUBLIC_REPO" push
