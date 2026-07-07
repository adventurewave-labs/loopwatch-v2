#!/usr/bin/env bash
# loopwatch — nightly pipeline: chat/git deltas -> claude -p extraction -> static catalog -> git push -> Vercel
# usage: loopwatch-run.sh [--dry-run] [--list-sources]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export ROOT_DIR

CONF="${LOOPWATCH_CONF:-$ROOT_DIR/loopwatch.conf}"
if [[ ! -f "$CONF" ]]; then
  echo "FATAL: no config at $CONF — cp loopwatch.conf.example loopwatch.conf and edit it" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# defaults (config may override any of these)
: "${SITE_DIR:=$ROOT_DIR/site}"
: "${STATE_DIR:=$ROOT_DIR/state}"
: "${CLAUDE_BIN:=claude}"
: "${MODEL:=sonnet}"
: "${MAX_TURNS:=50}"
: "${MAX_FILE_KB:=200}"
: "${ACTIVITY_MIN_BYTES:=300}"
: "${GIT_INCLUDE_PATCH:=false}"
: "${PULL:=true}"
: "${PUSH:=true}"
: "${SKIP_EMPTY:=true}"

DRY_RUN=false
LIST_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --list-sources) LIST_ONLY=true ;;
    -h|--help)      sed -n '2,3s/^# //p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

RUN_DATE="$(date +%F)"
RUN_TS="$(date +%F_%H%M%S)"
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/failed"
LOG="$STATE_DIR/logs/$RUN_TS.log"
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$LOG" >&2; }

# dependency preflight
for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FATAL: missing dependency: $dep" >&2; exit 1; }
done
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  echo "FATAL: claude CLI not found: $CLAUDE_BIN — set CLAUDE_BIN in loopwatch.conf (\`which claude\`)" >&2
  exit 1
}

MANIFEST="$SITE_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "FATAL: manifest not found: $MANIFEST" >&2; exit 1; }

REPO_DIR="${REPO_DIR:-$(git -C "$SITE_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

WATERMARKS="$STATE_DIR/watermarks.json"
[[ -f "$WATERMARKS" ]] || echo '{"files":{},"git":{}}' > "$WATERMARKS"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/collect.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/publish.sh"

if [[ "$LIST_ONLY" == "true" ]]; then
  list_sources
  exit 0
fi

# single-instance lock (mkdir-based — flock(1) is not on stock macOS)
LOCK="$STATE_DIR/.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  log "lock held ($LOCK) — another run active; exiting"
  exit 0
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch.XXXXXX")"
KEEP_STAGING=false
cleanup() {
  rmdir "$LOCK" 2>/dev/null || true
  if [[ "$KEEP_STAGING" == "true" ]]; then
    log "staging kept for inspection: $STAGING"
  else
    rm -rf "$STAGING"
  fi
}
trap cleanup EXIT

autopsy() {
  cp -R "$STAGING" "$STATE_DIR/failed/$RUN_TS" 2>/dev/null || true
  log "autopsy saved: $STATE_DIR/failed/$RUN_TS"
  # keep the 5 most recent autopsies
  ls -1t "$STATE_DIR/failed" 2>/dev/null | tail -n +6 | while IFS= read -r d; do
    rm -rf "${STATE_DIR:?}/failed/$d"
  done
}
die() { log "FATAL: $*"; autopsy; exit 1; }
trap 'log "unexpected error (line $LINENO)"; autopsy' ERR

mkdir -p "$STAGING/bundle/transcripts" "$STAGING/bundle/git" "$STAGING/pages"

log "collecting deltas -> $STAGING"
collect_all
log "bundle: $(du -sk "$STAGING/bundle" | awk '{print $1}')KB"

if [[ "$SKIP_EMPTY" == "true" ]] && ! has_activity; then
  log "no meaningful new activity — saving watermarks, skipping extraction"
  if [[ "$DRY_RUN" != "true" ]]; then
    cp "$STAGING/new-watermarks.json" "$WATERMARKS"
  fi
  exit 0
fi

log "extraction: $CLAUDE_BIN -p (model=$MODEL, max-turns=$MAX_TURNS)"
set +e
( cd "$STAGING" && "$CLAUDE_BIN" -p "$(cat "$ROOT_DIR/prompts/extract.md")" \
    --model "$MODEL" \
    --max-turns "$MAX_TURNS" \
    --allowedTools "Read,Write,Glob,Grep" ) < /dev/null > "$STAGING/claude-out.txt" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || die "claude -p exited $rc (see claude-out.txt in the autopsy dir)"

META="$STAGING/run-meta.json"
[[ -f "$META" ]] || die "extractor produced no run-meta.json (see claude-out.txt in the autopsy dir)"
validate_meta "$META"
N_PAGES="$(jq '.pages | length' "$META")"
log "extraction ok — $N_PAGES candidate page(s)"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[dry-run] no publish. candidates:"
  jq -r '.pages[] | "  [\(.category)] \(.title)  (\(.slug))"' "$META" | tee -a "$LOG" >&2
  log "[dry-run] digest: $(jq -r '.digest_summary' "$META")"
  KEEP_STAGING=true
  exit 0
fi

[[ -n "$REPO_DIR" ]] || die "SITE_DIR is not inside a git repo and REPO_DIR is unset"
publish_run "$META"
