#!/usr/bin/env bash
# loopwatch — activity deltas -> headless claude extraction -> static catalog
# usage: loopwatch-run.sh [--dry-run] [--list-sources] [--target nightly|manual]
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export ROOT_DIR

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/loopwatch"
CONF="${LOOPWATCH_CONF:-$CONFIG_HOME/loopwatch.conf}"
if [[ ! -f "$CONF" ]]; then
  echo "FATAL: no config at $CONF — run: mkdir -p \"$CONFIG_HOME\" && cp \"$ROOT_DIR/loopwatch.conf.example\" \"$CONF\"" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# defaults (config may override any of these)
: "${STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/loopwatch}"
: "${CLAUDE_BIN:=claude}"
: "${MODEL:=sonnet}"
: "${MAX_TURNS:=50}"
: "${BUDGET_USD:=1.00}"
: "${MAX_FILE_KB:=120}"
: "${MAX_BUNDLE_KB:=300}"
: "${ACTIVITY_MIN_BYTES:=2000}"
: "${FIRST_RUN_LOOKBACK_HOURS:=48}"
: "${PULL:=true}"
: "${PUSH:=true}"
: "${SKIP_EMPTY:=true}"
: "${SITE_DIR:=}"

DRY_RUN=false
LIST_ONLY=false
RUN_TARGET="${LOOPWATCH_TARGET:-manual}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --list-sources) LIST_ONLY=true ;;
    --target)       shift; RUN_TARGET="${1:-manual}" ;;
    -h|--help)      sed -n '2,3s/^# //p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

RUN_DATE="$(date +%F)"
RUN_TS="$(date +%F_%H%M%S)"
RUN_START="$(date +%s)"
# Fixed working directory for every headless claude call (R-4): its encoded
# project dir is excluded from collection, so loopwatch never mines itself.
RUN_DIR="$STATE_DIR/run"
LEDGER="${LEDGER:-$STATE_DIR/runs.jsonl}"
mkdir -p "$STATE_DIR/logs" "$STATE_DIR/failed"
LOG="$STATE_DIR/logs/$RUN_TS.log"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"

# dependency preflight
for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FATAL: missing dependency: $dep" >&2; exit 1; }
done
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  echo "FATAL: claude CLI not found: $CLAUDE_BIN — set CLAUDE_BIN in $CONF (\`which claude\`)" >&2
  exit 1
}

[[ -n "$SITE_DIR" ]] || { echo "FATAL: SITE_DIR is not set in $CONF" >&2; exit 1; }
MANIFEST="$SITE_DIR/manifest.json"
[[ -f "$MANIFEST" ]] || { echo "FATAL: manifest not found: $MANIFEST" >&2; exit 1; }
REPO_DIR="${REPO_DIR:-$(git -C "$SITE_DIR" rev-parse --show-toplevel 2>/dev/null || true)}"

# Watermarks are local state (never committed): hashed source keys -> offsets/shas.
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
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" "$RUN_DIR/pages"
: > "$RUN_DIR/usage.jsonl"
BUNDLE_BYTES=0
TRIMMED_BYTES=0
POSTSCAN_DROPS=0
LEDGER_DONE=false

autopsy() {
  cp -R "$RUN_DIR" "$STATE_DIR/failed/$RUN_TS" 2>/dev/null || true
  log "autopsy saved: $STATE_DIR/failed/$RUN_TS"
  # keep the 5 most recent autopsies
  ls -1t "$STATE_DIR/failed" 2>/dev/null | tail -n +6 | while IFS= read -r d; do
    rm -rf "${STATE_DIR:?}/failed/$d"
  done
}
finish() {  # finish <status> <skipped_reason> <pages>
  if [[ "$LEDGER_DONE" != "true" ]]; then
    LEDGER_DONE=true
    ledger_append "$1" "$2" "${3:-0}" || log "WARN: ledger append failed"
  fi
}
die() { log "FATAL: $*"; autopsy; finish failed "${DIE_REASON:-error}" 0; exit 1; }
trap 'log "unexpected error (line $LINENO)"; autopsy; finish failed error 0' ERR

log "collecting deltas -> $RUN_DIR"
collect_all
log "bundle: $((BUNDLE_BYTES / 1024))KB (cap ${MAX_BUNDLE_KB}KB, trimmed ${TRIMMED_BYTES}B), activity $(activity_bytes)B"

if [[ "$SKIP_EMPTY" == "true" ]] && ! has_activity; then
  log "no meaningful new activity (< ${ACTIVITY_MIN_BYTES}B) — skipping extraction"
  if [[ "$DRY_RUN" != "true" ]]; then
    cp "$RUN_DIR/new-watermarks.json" "$WATERMARKS"
  fi
  finish skipped below_activity_min 0
  exit 0
fi

log "extraction: $CLAUDE_BIN -p (model=$MODEL, budget=\$$BUDGET_USD)"
if ! run_claude extract "$MODEL" "$ROOT_DIR/prompts/extract.md" "Read,Write,Glob,Grep" "$MAX_TURNS" "$BUDGET_USD"; then
  case "$CLAUDE_LAST_SUBTYPE" in
    *budget*) DIE_REASON=budget_exceeded; die "claude -p hit the \$$BUDGET_USD budget cap (watermarks not advanced)" ;;
    *)        DIE_REASON=claude_error;    die "claude -p failed (subtype=$CLAUDE_LAST_SUBTYPE) — see extract.json/extract.err in the autopsy dir" ;;
  esac
fi

META="$RUN_DIR/run-meta.json"
[[ -f "$META" ]] || { DIE_REASON=no_meta; die "extractor produced no run-meta.json"; }
validate_meta "$META"
N_PAGES="$(jq '.pages | length' "$META")"
log "extraction ok — $N_PAGES candidate page(s), cost \$$(jq -s 'map(.cost_usd) | add // 0' "$RUN_DIR/usage.jsonl")"

if [[ "$DRY_RUN" == "true" ]]; then
  log "[dry-run] no publish. candidates:"
  jq -r '.pages[] | "  [\(.category)] \(.title)  (\(.slug))"' "$META" | tee -a "$LOG" >&2
  log "[dry-run] digest: $(jq -r '.digest_summary' "$META")"
  log "[dry-run] staging kept for inspection: $RUN_DIR"
  finish dry_run "" "$N_PAGES"
  exit 0
fi

[[ -n "$REPO_DIR" ]] || die "SITE_DIR is not inside a git repo and REPO_DIR is unset"
publish_run "$META"
cp "$RUN_DIR/new-watermarks.json" "$WATERMARKS"
finish published "" "${INSTALLED_PAGES:-0}"
