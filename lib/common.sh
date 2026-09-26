#!/usr/bin/env bash
# loopwatch lib — shared helpers (sourced; do not execute). bash 3.2 + BSD/GNU userland safe.

log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "${LOG:-/dev/null}" >&2; }

# sha256 of a string, first 16 hex chars — used for state keys so absolute
# paths (which can carry client project names) never land in state files.
hash_key() {
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | cut -c1-16
  else
    printf '%s' "$1" | shasum -a 256 | cut -c1-16
  fi
}

# file mtime as epoch seconds (GNU stat first; BSD stat rejects -c and falls through)
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

file_size() { wc -c < "$1" | tr -d ' '; }

now_epoch() { date +%s; }

# local ISO-8601 timestamp with offset, e.g. 2026-09-25T21:30:00-0600
now_local_iso() { date +%Y-%m-%dT%H:%M:%S%z; }

# Claude Code stores a session under ~/.claude/projects/<cwd with every
# non-alphanumeric char replaced by '-'>. Verified on 2.1.283 (docs/revival-notes.md).
encode_project_dir() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }

# ── claude CLI capability detection ─────────────────────────────────────
CLAUDE_HELP=""
claude_supports() {
  if [[ -z "$CLAUDE_HELP" ]]; then
    CLAUDE_HELP="$("$CLAUDE_BIN" --help 2>/dev/null || true)"
    [[ -n "$CLAUDE_HELP" ]] || CLAUDE_HELP="(none)"
  fi
  printf '%s' "$CLAUDE_HELP" | grep -q -- "$1"
}

# run_claude <stage> <model> <system-prompt-file> <input-file> <schema-file> <budget-usd>
#
# Structured mode (the only mode): one headless call with NO tools (--tools ""), the
# stage prompt as the system prompt, the data on stdin, and the answer constrained by
# --json-schema (read back from .structured_output). The model cannot touch the
# filesystem, so nothing outside the given input can reach it, and nothing it writes
# lands on disk except through our validator. Extended thinking is off by default
# (THINKING_TOKENS=0): on the measured sample it was most of the triage output cost.
# Runs from $RUN_DIR (fixed cwd, R-4). Result JSON in $RUN_DIR/<stage>.json; a usage
# record is appended to $USAGE_FILE. Returns the CLI exit code; sets CLAUDE_LAST_SUBTYPE.
CLAUDE_LAST_SUBTYPE=""
run_claude() {
  local stage="$1" model="$2" sys_file="$3" input_file="$4" schema_file="$5" budget="$6"
  local out="$RUN_DIR/$stage.json" err="$RUN_DIR/$stage.err" rc
  local -a args
  args=(-p --model "$model" --output-format json --tools ""
        --system-prompt "$(cat "$sys_file")"
        --json-schema "$(jq -c . "$schema_file")")
  if claude_supports --no-session-persistence; then args+=(--no-session-persistence); fi
  if claude_supports --strict-mcp-config;      then args+=(--strict-mcp-config); fi
  if [[ -n "$budget" ]] && claude_supports --max-budget-usd; then args+=(--max-budget-usd "$budget"); fi
  if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    args+=($CLAUDE_EXTRA_ARGS)
  fi

  set +e
  ( cd "$RUN_DIR" && MAX_THINKING_TOKENS="${THINKING_TOKENS:-0}" "$CLAUDE_BIN" "${args[@]}" ) < "$input_file" > "$out" 2> "$err"
  rc=$?
  set -e
  # a result the CLI flags as an error (budget/turn cap, API error) is a failure even on exit 0
  if [[ "$rc" -eq 0 ]] && jq -e '.is_error == true' "$out" >/dev/null 2>&1; then rc=1; fi

  # Parse usage tolerantly: a non-JSON stdout (old CLI, crash) records nulls.
  local rec
  rec="$(jq -c --arg stage "$stage" --arg model "$model" --argjson rc "$rc" '
      {stage: $stage, model: $model, rc: $rc,
       in: (((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0))),
       cached: (.usage.cache_read_input_tokens // 0),
       out: (.usage.output_tokens // 0),
       cost_usd: (.total_cost_usd // 0),
       duration_ms: (.duration_ms // 0),
       is_error: (.is_error // ($rc != 0)),
       subtype: (.subtype // "")}' "$out" 2>/dev/null || true)"
  if [[ -z "$rec" ]]; then
    rec="$(jq -nc --arg stage "$stage" --arg model "$model" --argjson rc "$rc" \
      '{stage: $stage, model: $model, rc: $rc, in: 0, cached: 0, out: 0, cost_usd: 0,
        duration_ms: 0, is_error: ($rc != 0), subtype: "unparsed_output"}')"
  fi
  printf '%s\n' "$rec" >> "$USAGE_FILE"
  CLAUDE_LAST_SUBTYPE="$(printf '%s' "$rec" | jq -r '.subtype')"
  return "$rc"
}

# ── run ledger (Turbo Rig seam, R-12) ───────────────────────────────────
# One JSON line per run in $LEDGER, field names aligned with Turbo Rig's
# gate-log (ts, repo, target, model, in, cached, out, cost_usd, duration_ms)
# plus loopwatch fields. Separate file so activity.py verdict stats stay clean.
ledger_append() {
  local status="$1" skipped_reason="$2" pages="${3:-0}"
  local usage="${USAGE_FILE:-/dev/null}" wall_ms
  wall_ms=$(( ($(now_epoch) - RUN_START) * 1000 ))
  mkdir -p "$(dirname "$LEDGER")"
  jq -sc \
    --arg ts "$(now_local_iso)" \
    --arg target "$RUN_TARGET" \
    --arg run_id "$RUN_TS" \
    --arg status "$status" \
    --arg skipped "$skipped_reason" \
    --argjson pages "$pages" \
    --argjson wall "$wall_ms" \
    --argjson bundle_bytes "${BUNDLE_BYTES:-0}" \
    --argjson trimmed "${TRIMMED_BYTES:-0}" \
    --argjson drops "${POSTSCAN_DROPS:-0}" \
    --argjson vdrops "${VALIDATOR_DROPS:-0}" \
    --arg sbskip "${STAGE_B_SKIP:-}" \
    --argjson dry "$([[ "${DRY_RUN:-false}" == "true" ]] && echo true || echo false)" '
    {
      ts: $ts, repo: "loopwatch", target: $target,
      model: ((map(.model) | unique | join("+")) | if . == "" then null else . end),
      in:      (map(.in)       | add // 0),
      cached:  (map(.cached)   | add // 0),
      out:     (map(.out)      | add // 0),
      cost_usd:((map(.cost_usd) | add // 0) * 1000000 | round / 1000000),
      duration_ms: $wall,
      pages: $pages,
      skipped_reason: (if $skipped == "" then null else $skipped end),
      status: $status, run_id: $run_id, dry_run: $dry,
      bundle_bytes: $bundle_bytes, trimmed_bytes: $trimmed, postscan_drops: $drops,
      validator_drops: $vdrops,
      stage_b_skipped: (if $sbskip == "" then null else $sbskip end),
      stages: map({stage, model, cost_usd, in, cached, out, subtype})
    }' "$usage" >> "$LEDGER"
}
