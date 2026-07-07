#!/usr/bin/env bash
# ship.sh — the release loop, one command:
#   test locally -> bump VERSION -> commit -> tag vX.Y.Z -> push
# GitHub Actions then re-runs e2e (ubuntu + macos) and publishes the release.
# usage: ship.sh [patch|minor|major] ["release message"]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

LEVEL="${1:-patch}"
MSG="${2:-}"

./bin/smoke-test.sh

cur="$(cat VERSION 2>/dev/null || echo 0.0.0)"
IFS=. read -r maj min pat <<EOF
$cur
EOF
case "$LEVEL" in
  major) maj=$((maj + 1)); min=0; pat=0 ;;
  minor) min=$((min + 1)); pat=0 ;;
  patch) pat=$((pat + 1)) ;;
  *) echo "usage: ship.sh [patch|minor|major] [\"message\"]" >&2; exit 2 ;;
esac
new="$maj.$min.$pat"

echo "$new" > VERSION
git add -A
git commit -m "release: v$new${MSG:+ — $MSG}"
git tag -a "v$new" -m "${MSG:-loopwatch v$new}"
git push
git push origin "v$new"
echo "shipped v$new — Actions runs e2e and publishes the release"
