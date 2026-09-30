#!/usr/bin/env bash
# loopwatch installer — installs the TOOL, never a schedule.
#   curl-free: gh repo clone adventurewave-labs/loopwatch-v2 ~/.local/share/loopwatch && ~/.local/share/loopwatch/bin/install.sh
# or, from any checkout:  bin/install.sh
# Result: code in ~/.local/share/loopwatch (updated with `loopwatch update`), config in
# ~/.config/loopwatch, state in ~/.local/state/loopwatch, `loopwatch` on ~/.local/bin.
# The nightly job stays off until you run `loopwatch schedule install`.
set -euo pipefail

REPO="${LOOPWATCH_REPO:-adventurewave-labs/loopwatch-v2}"
DEST="${LOOPWATCH_HOME:-$HOME/.local/share/loopwatch}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for dep in jq git gh claude; do
  command -v "$dep" >/dev/null 2>&1 || echo "WARN: $dep not on PATH — loopwatch needs it at run time" >&2
done

if [[ "$HERE" != "$DEST" ]]; then
  if [[ -d "$DEST/.git" ]]; then
    git -C "$DEST" pull --ff-only -q
    echo "updated: $DEST"
  else
    mkdir -p "$(dirname "$DEST")"
    gh repo clone "$REPO" "$DEST" -- -q
    echo "cloned:  $REPO -> $DEST"
  fi
fi

"$DEST/bin/loopwatch" setup
