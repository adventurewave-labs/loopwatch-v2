#!/usr/bin/env bash
# loopwatch — activity deltas -> headless claude extraction -> static catalog
# usage: loopwatch-run.sh [--dry-run] [--list-sources] [--preflight] [--target nightly|manual] [--export-md DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export ROOT_DIR

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}/loopwatch"
CONF="${LOOPWATCH_CONF:-$CONFIG_HOME/loopwatch.conf}"
if [[ ! -f "$CONF" ]]; then
  echo "FATAL: no config at $CONF — run: mkdir -p \"$CONFIG_HOME\" && cp \"$ROOT_DIR/loopwatch.conf.example\" \"$CONF\"" >&2
  exit 1
fi
# OTel export is opt-in from the conf only: ignore OTEL_* the user exports for other tools
unset OTEL_EXPORT_DIR OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS
# shellcheck disable=SC1090
source "$CONF"

# defaults (config may override any of these)
: "${STATE_DIR:=${XDG_STATE_HOME:-$HOME/.local/state}/loopwatch}"
: "${CLAUDE_BIN:=claude}"
: "${MODEL:=sonnet}"                    # stage B (writing)
: "${TRIAGE_MODEL:=haiku}"             # stage A (triage)
: "${FALLBACK_MODEL:=haiku}"           # writer fallback when MODEL is overloaded ("" = none)
: "${TRIAGE_FALLBACK_MODEL:=}"         # triage fallback (default none: haiku is already the cheapest)
: "${CLAUDE_RETRIES:=2}"               # extra attempts on transient API/network failures
: "${CLAUDE_RETRY_BASE_S:=15}"         # backoff base seconds (doubles each retry, plus jitter)
: "${THINKING_TOKENS:=0}"
: "${TRIAGE_BUDGET_USD:=0.30}"
: "${MAX_CANDIDATES:=5}"
: "${EXCERPT_MAX_KB:=24}"
: "${EXCERPT_TOTAL_KB:=80}"
: "${EXCERPT_CONTEXT_LINES:=5}"
: "${BUDGET_USD:=1.00}"
: "${MAX_FILE_KB:=120}"
: "${MAX_BUNDLE_KB:=300}"
: "${ACTIVITY_MIN_BYTES:=2000}"
: "${FIRST_RUN_LOOKBACK_HOURS:=48}"
: "${LOCK_STALE_HOURS:=6}"
: "${GITHUB_INDEX_LAG_MIN:=15}"
: "${SKIP_EMPTY:=true}"
: "${GH_BIN:=gh}"
: "${CATALOG_REPO:=adventurewave-labs/loopwatch-catalog}"
: "${CATALOG_BASE:=main}"
: "${CATALOG_DIR:=$STATE_DIR/catalog}"
: "${GITHUB_AUTHOR:=}"
: "${EXPORT_MD_DIR:=}"
: "${EXPORT_DIGEST_TO:=}"
: "${NEAR_DUP_THRESHOLD:=0.55}"
: "${RELATED_PAGES:=3}"
: "${RELATED_MIN_SCORE:=1.5}"
: "${MONTHLY_BUDGET_USD:=20.00}"         # calendar-month cap across runs (0 = off); fails closed, activity stays queued
: "${COST_ANOMALY_FACTOR:=3}"           # flag a run costing >= this x the rolling median
: "${RETENTION_DAYS:=30}"              # prune logs/autopsies/private page copies older than this (0 = keep)
: "${GROUNDING:=on}"                   # code-token groundedness guard (on|off)
: "${GROUNDING_DROP_MIN:=4}"           # drop a page with >= this many unsupported code tokens (and >= half)
: "${OTEL_EXPORT_DIR:=}"
: "${OTEL_EXPORTER_OTLP_ENDPOINT:=}"
: "${OTEL_EXPORTER_OTLP_HEADERS:=}"
# default scopes only when the conf does not mention GITHUB_SCOPES at all;
# GITHUB_SCOPES=() in the conf turns the GitHub source off
if ! declare -p GITHUB_SCOPES >/dev/null 2>&1; then
  GITHUB_SCOPES=("user:marcuspat" "org:adventurewave-labs" "org:creandotumatrix-labs")
fi
PREFLIGHT_NEEDS_GH=true
: "${REDACT_LIST:=$CONFIG_HOME/redact.list}"
: "${SITE_VISIBILITY:=}"
: "${ALLOW_PUBLIC:=false}"

DRY_RUN=false
LIST_ONLY=false
PREFLIGHT_ONLY=false
RUN_TARGET="${LOOPWATCH_TARGET:-manual}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=true ;;
    --list-sources) LIST_ONLY=true ;;
    --preflight)    PREFLIGHT_ONLY=true ;;
    --target)       shift; RUN_TARGET="${1:-manual}" ;;
    --export-md)    shift; EXPORT_MD_DIR="${1:?--export-md needs a directory}" ;;
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
LOG_JSONL="$STATE_DIR/logs/$RUN_TS.jsonl"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/otel.sh"
# one trace per run: OTel spans and every structured log line (LOG_JSONL) carry these ids
RUN_TRACE_ID="$(otel_hex 16)"; RUN_ROOT_SPAN="$(otel_hex 8)"
PROMPT_VERSION="$(prompt_version "$ROOT_DIR")"

# dependency preflight
for dep in jq git; do
  command -v "$dep" >/dev/null 2>&1 || { echo "FATAL: missing dependency: $dep" >&2; exit 1; }
done
command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  echo "FATAL: claude CLI not found: $CLAUDE_BIN — set CLAUDE_BIN in $CONF (\`which claude\`)" >&2
  exit 1
}

SITE_DIR="$CATALOG_DIR/site"
MANIFEST="$SITE_DIR/manifest.json"

# Watermarks are local state (never committed): hashed source keys -> offsets/shas.
WATERMARKS="$STATE_DIR/watermarks.json"
[[ -f "$WATERMARKS" ]] || echo '{"files":{},"git":{}}' > "$WATERMARKS"

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/collect.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/publish.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/redact.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/preflight.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/extract.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/collect_github.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/catalog.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/export.sh"

if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
  preflight
  exit $?
fi

if [[ "$LIST_ONLY" == "true" ]]; then
  list_sources
  list_github_sources
  exit 0
fi

# single-instance lock (mkdir-based — flock(1) is not on stock macOS). The holder's PID
# is recorded; a lock whose PID is gone, or older than LOCK_STALE_HOURS, is reclaimed
# so one crash can never silently stop every later run.
LOCK="$STATE_DIR/.lock"
USAGE_FILE=/dev/null
LEDGER_DONE=false
take_lock() {
  if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; return 0; fi
  local pid age
  pid="$(cat "$LOCK/pid" 2>/dev/null || true)"
  age=$(( $(now_epoch) - $(file_mtime "$LOCK") ))
  if { [[ -n "$pid" ]] && ! kill -0 "$pid" 2>/dev/null; } || [[ "$age" -gt $(( LOCK_STALE_HOURS * 3600 )) ]] \
     || { [[ -z "$pid" ]] && [[ "$age" -gt 60 ]]; }; then
    log "reclaiming stale lock (pid ${pid:-none}, ${age}s old)"
    rm -rf "$LOCK"
    if mkdir "$LOCK" 2>/dev/null; then echo "$$" > "$LOCK/pid"; return 0; fi
  fi
  return 1
}
if ! take_lock; then
  log "lock held by a live run ($LOCK) — exiting"
  LEDGER_DONE=true
  ledger_append skipped locked 0 || true
  exit 0
fi
# One exit path: any non-zero exit (die, or set -e on an unexpected failure) leaves an
# autopsy and a ledger row. Subshells do not inherit this trap, so a failing command
# substitution can never write a spurious "failed" row.
on_exit() {
  local rc="$1"
  if [[ "$rc" -ne 0 && "$LEDGER_DONE" != "true" ]]; then
    log "run failed (exit $rc${DIE_REASON:+, $DIE_REASON})"
    autopsy
    finish failed "${DIE_REASON:-error}" 0
  fi
  rm -rf "$LOCK" 2>/dev/null || true
}
trap 'on_exit $?' EXIT

retention_prune
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" "$RUN_DIR/pages"
: > "$RUN_DIR/usage.jsonl"
USAGE_FILE="$RUN_DIR/usage.jsonl"
mkdir -p "$STATE_DIR/private" && chmod 700 "$STATE_DIR/private"
BUNDLE_BYTES=0
TRIMMED_BYTES=0
POSTSCAN_DROPS=0
VALIDATOR_DROPS=0
NEAR_DUP_DROPS=0
RELATED_LINKS=0
GROUNDING_DROPS=0
UNGROUNDED_TOKENS=0
STAGE_B_SKIP=""

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
die() { log "FATAL: $*"; exit 1; }

# privacy preflight (R-5): a publishing run never starts if it fails
if ! preflight > "$RUN_DIR/preflight.txt" 2>&1; then
  if [[ "$DRY_RUN" == "true" ]]; then
    log "preflight FAILED — continuing because this is a dry run (nothing is published):"
    grep '^FAIL' "$RUN_DIR/preflight.txt" | while IFS= read -r l; do log "  $l"; done
  else
    grep '^FAIL' "$RUN_DIR/preflight.txt" | while IFS= read -r l; do log "  $l"; done
    log "preflight failed — nothing collected, nothing published"
    finish failed preflight_failed 0
    exit 1
  fi
fi
build_rules
ensure_catalog

log "collecting deltas -> $RUN_DIR"
canary_init
collect_all
n_bundle="$(find "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" -type f 2>/dev/null | wc -l | tr -d ' ')"
if ! why="$(canary_verify "$n_bundle")"; then
  DIE_REASON=canary_leak; die "privacy self-test failed after collection: $why (nothing sent to a model)"
fi
CANARY_STATUS=ok
log "bundle: $((BUNDLE_BYTES / 1024))KB (cap ${MAX_BUNDLE_KB}KB, trimmed ${TRIMMED_BYTES}B), activity $(activity_bytes)B"

if [[ "$SKIP_EMPTY" == "true" ]] && ! has_activity; then
  log "no meaningful new activity (< ${ACTIVITY_MIN_BYTES}B) — skipping extraction"
  if [[ "$DRY_RUN" != "true" ]]; then
    cp "$RUN_DIR/new-watermarks.json" "$WATERMARKS"
  fi
  finish skipped below_activity_min 0
  exit 0
fi

cost_guard
run_extraction
RUN_COST="$(jq -s 'map(.cost_usd) | add // 0' "$RUN_DIR/usage.jsonl")"
COST_ANOMALY_MEDIAN="$(cost_anomaly "$RUN_COST")"
if [[ -n "$COST_ANOMALY_MEDIAN" ]]; then
  log "WARN: cost anomaly: this run cost \$$RUN_COST, >= ${COST_ANOMALY_FACTOR:-3}x the rolling median \$$COST_ANOMALY_MEDIAN"
fi
if ! why="$(canary_verify 0)"; then
  DIE_REASON=canary_leak; die "privacy self-test failed after extraction: $why"
fi

META="$RUN_DIR/run-meta.json"
validate_meta "$META"
postscan "$META"
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

publish_run "$META"
cp "$RUN_DIR/new-watermarks.json" "$WATERMARKS"
# optional seams (never fail the run: the PR is already out)
if [[ -n "$EXPORT_MD_DIR" ]]; then export_md "$EXPORT_MD_DIR" || log "WARN: --export-md failed"; fi
if [[ -n "$EXPORT_DIGEST_TO" ]]; then export_digest "$EXPORT_DIGEST_TO" || log "WARN: digest export failed"; fi
finish published "" "${INSTALLED_PAGES:-0}"
