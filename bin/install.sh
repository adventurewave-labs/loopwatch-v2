#!/usr/bin/env bash
# Install the loopwatch launchd agent (macOS). usage: install.sh [HOUR] [MINUTE]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HOUR="${1:-21}"
MINUTE="${2:-30}"
LABEL="com.marcuspatman.loopwatch"
DEST="$HOME/Library/LaunchAgents/$LABEL.plist"

[[ -f "$ROOT_DIR/loopwatch.conf" ]] || {
  echo "FATAL: create loopwatch.conf first (cp loopwatch.conf.example loopwatch.conf)" >&2
  exit 1
}

mkdir -p "$HOME/Library/LaunchAgents" "$ROOT_DIR/state/logs"

sed -e "s|__LOOPWATCH_DIR__|$ROOT_DIR|g" \
    -e "s|__HOME_DIR__|$HOME|g" \
    -e "s|__HOUR__|$HOUR|g" \
    -e "s|__MINUTE__|$MINUTE|g" \
    "$ROOT_DIR/launchd/$LABEL.plist" > "$DEST"

launchctl bootout "gui/$(id -u)" "$DEST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$DEST"

echo "installed: $DEST (daily at $HOUR:$(printf '%02d' "$MINUTE"))"
echo "kick now:  launchctl kickstart -k gui/$(id -u)/$LABEL"
echo "remove:    launchctl bootout gui/$(id -u) $DEST && rm $DEST"
echo
echo "crontab alternative:"
echo "  $MINUTE $HOUR * * * \"$ROOT_DIR/bin/loopwatch-run.sh\""
