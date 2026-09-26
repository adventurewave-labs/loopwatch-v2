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

# prompt_version [root]: 12-hex content hash of everything that defines what the models are
# asked (prompts/*.md) and allowed to answer (schemas/*.json), in byte order of file name.
# Stamped on every ledger row, OTel span and eval golden, so any change in quality or cost
# can be attributed to an exact prompt revision.
prompt_version() {
  local root="${1:-$ROOT_DIR}" f
  for f in "$root"/prompts/*.md "$root"/schemas/*.json; do
    [[ -f "$f" ]] || continue
    printf '== %s ==\n' "${f##*/}"; cat "$f"
  done | LC_ALL=C hash_stream | cut -c1-12
}
hash_stream() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi
}

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
  local stage="$1" model="$2" sys_file="$3" input_file="$4" schema_file="$5" budget="$6" fallback="${7:-}" attempt="${8:-1}" is_fb="${9:-false}"
  local out="$RUN_DIR/$stage.json" err="$RUN_DIR/$stage.err" rc t0
  local -a args
  args=(-p --model "$model" --output-format json --tools ""
        --system-prompt "$(cat "$sys_file")"
        --json-schema "$(jq -c . "$schema_file")")
  # The isolation guarantee rests on these: --tools "" removes built-in tools, and
  # --strict-mcp-config stops user-configured MCP servers (whose tools may be pre-allowed)
  # from loading. A CLI without them fails closed instead of silently running with tools.
  local req
  for req in --tools --json-schema --system-prompt --strict-mcp-config; do
    claude_supports "$req" || { DIE_REASON=cli_unsupported; die "claude CLI lacks $req (needed for tool-free structured mode); upgrade claude"; }
  done
  args+=(--strict-mcp-config)
  if claude_supports --no-session-persistence; then args+=(--no-session-persistence); fi
  # in-call fallback: the CLI itself switches model when the primary is overloaded/unavailable
  if [[ -n "$fallback" && "$fallback" != "$model" ]] && claude_supports --fallback-model; then
    args+=(--fallback-model "$fallback")
  fi
  if [[ -n "$budget" ]] && claude_supports --max-budget-usd; then args+=(--max-budget-usd "$budget"); fi
  if [[ -n "${CLAUDE_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    args+=($CLAUDE_EXTRA_ARGS)
  fi

  t0="$(now_epoch)"
  set +e
  ( cd "$RUN_DIR" && MAX_THINKING_TOKENS="${THINKING_TOKENS:-0}" "$CLAUDE_BIN" "${args[@]}" ) < "$input_file" > "$out" 2> "$err"
  rc=$?
  set -e
  # a result the CLI flags as an error (budget/turn cap, API error) is a failure even on exit 0
  if [[ "$rc" -eq 0 ]] && jq -e '.is_error == true' "$out" >/dev/null 2>&1; then rc=1; fi

  # Parse usage tolerantly: a non-JSON stdout (old CLI, crash) records nulls.
  local rec
  rec="$(jq -c --arg stage "$stage" --arg model "$model" --argjson rc "$rc" --argjson t0 "$t0" --argjson attempt "$attempt" --argjson fb "$is_fb" '
      {stage: $stage, model: $model, rc: $rc, start_s: $t0, attempt: $attempt, fallback_attempt: $fb,
       models_used: ((.modelUsage // {}) | keys),
       in: (((.usage.input_tokens // 0) + (.usage.cache_creation_input_tokens // 0))),
       cached: (.usage.cache_read_input_tokens // 0),
       out: (.usage.output_tokens // 0),
       cost_usd: (.total_cost_usd // 0),
       duration_ms: (.duration_ms // 0),
       is_error: (.is_error // ($rc != 0)),
       subtype: (.subtype // "")}' "$out" 2>/dev/null || true)"
  if [[ -z "$rec" ]]; then
    rec="$(jq -nc --arg stage "$stage" --arg model "$model" --argjson rc "$rc" --argjson t0 "$t0" --argjson attempt "$attempt" --argjson fb "$is_fb" \
      '{stage: $stage, model: $model, rc: $rc, start_s: $t0, attempt: $attempt, fallback_attempt: $fb, models_used: [], in: 0, cached: 0, out: 0, cost_usd: 0,
        duration_ms: 0, is_error: ($rc != 0), subtype: "unparsed_output"}')"
  fi
  printf '%s\n' "$rec" >> "$USAGE_FILE"
  CLAUDE_LAST_SUBTYPE="$(printf '%s' "$rec" | jq -r '.subtype')"
  return "$rc"
}

# claude_transient <stage>: 0 if the last call failed for a reason worth retrying (API
# overload, rate limit, 5xx, network), 1 otherwise. Budget caps and schema/parse problems
# are NOT transient: retrying them would only spend money again.
claude_transient() {
  local out="$RUN_DIR/$1.json" err="$RUN_DIR/$1.err" txt
  case "$CLAUDE_LAST_SUBTYPE" in *budget*|*max_turns*) return 1 ;; esac
  txt="$( { jq -r '[.result // "", .subtype // "", (.api_error_status // "" | tostring)] | join(" ")' "$out" 2>/dev/null; tail -c 4000 "$err" 2>/dev/null; } )"
  printf '%s' "$txt" | grep -Eqi 'overloaded|\b529\b|rate[ _-]?limit|\b429\b|\b50[0234]\b|internal server error|service unavailable|ECONNRESET|ETIMEDOUT|ECONNREFUSED|EAI_AGAIN|socket hang up|network error|fetch failed'
}

# call_stage <stage> <model> <fallback-model> <sys> <input> <schema> <budget>
#
# Resilient wrapper around run_claude:
#   * transient failures retry up to CLAUDE_RETRIES times with jittered exponential backoff
#     (CLAUDE_RETRY_BASE_S * 2^n + 0..base s); each retry's budget is the stage budget minus
#     what the stage has already spent, so retries can never exceed the cap
#   * the CLI's own --fallback-model handles overload inside a call; if the primary still
#     fails transiently after the retries, one last attempt runs ON the fallback model
#   * anything non-transient (budget cap, bad output) returns immediately
# Every attempt is a usage record (attempt=N), so the ledger shows retries and fallbacks.
call_stage() {
  local stage="$1" model="$2" fallback="$3" sys="$4" input="$5" schema="$6" budget="$7"
  local n=1 max=$(( ${CLAUDE_RETRIES:-2} + 1 )) base="${CLAUDE_RETRY_BASE_S:-15}" left spent delay is_fb=false
  while :; do
    spent="$(jq -s --arg s "$stage" 'map(select(.stage == $s) | .cost_usd) | add // 0' "$USAGE_FILE")"
    if [[ "$spent" == 0 ]]; then left="$budget"
    else left="$(jq -n --argjson b "$budget" --argjson s "$spent" '($b - $s) * 100 | floor / 100')"; fi
    if jq -e -n --argjson l "$left" '$l < 0.02' >/dev/null; then
      log "$stage: no budget left for another attempt (\$$left)"; CLAUDE_LAST_SUBTYPE="error_max_budget_usd"; return 1
    fi
    if run_claude "$stage" "$model" "$sys" "$input" "$schema" "$left" "$fallback" "$n" "$is_fb"; then return 0; fi
    claude_transient "$stage" || return 1
    if [[ "$n" -ge "$max" ]]; then
      if [[ -n "$fallback" && "$fallback" != "$model" ]]; then
        log "$stage: $model still failing after $n attempt(s); last try on fallback model $fallback"
        model="$fallback"; fallback=""; is_fb=true; n=$((n + 1)); max="$n"
        continue
      fi
      log "$stage: giving up after $n attempt(s) (transient: ${CLAUDE_LAST_SUBTYPE:-error})"; return 1
    fi
    delay=$(( base * (1 << (n - 1)) + (base > 0 ? RANDOM % (base + 1) : 0) ))
    log "$stage: transient failure on attempt $n/$max, retrying in ${delay}s"
    sleep "$delay"
    n=$((n + 1))
  done
}

# ── run ledger (Turbo Rig seam, R-12) ───────────────────────────────────
# One JSON line per run in $LEDGER, field names aligned with Turbo Rig's
# gate-log (ts, repo, target, model, in, cached, out, cost_usd, duration_ms)
# plus loopwatch fields. Separate file so activity.py verdict stats stay clean.
ledger_append() {
  local status="$1" skipped_reason="$2" pages="${3:-0}"
  local usage="${USAGE_FILE:-/dev/null}" wall_ms
  wall_ms=$(( ($(now_epoch) - RUN_START) * 1000 ))
  local row
  mkdir -p "$(dirname "$LEDGER")"
  row="$(jq -sc \
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
    --argjson ndrops "${NEAR_DUP_DROPS:-0}" \
    --arg pv "${PROMPT_VERSION:-}" \
    --arg sbskip "${STAGE_B_SKIP:-}" \
    --argjson dry "$([[ "${DRY_RUN:-false}" == "true" ]] && echo true || echo false)" '
    {
      ts: $ts, repo: "loopwatch", target: $target,
      prompt_version: (if $pv == "" then null else $pv end),
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
      validator_drops: $vdrops, near_dup_drops: $ndrops,
      stage_b_skipped: (if $sbskip == "" then null else $sbskip end),
      attempts: length,
      retries: (length - (map(.stage) | unique | length)),
      fallback_used: any(.[]; . as $r
                         | ($r.fallback_attempt // false)
                           or (($r.models_used // []) | length > 0
                               and (map(ascii_downcase | contains($r.model | ascii_downcase)) | any | not))),
      stages: map({stage, model, attempt, cost_usd, in, cached, out, subtype, models_used})
    }' "$usage")" || return 1
  printf '%s\n' "$row" >> "$LEDGER"
  # optional OpenTelemetry GenAI export (lib/otel.sh); never fails the run
  if declare -F otel_export >/dev/null; then otel_export "$row" || true; fi
}
