#!/usr/bin/env bash
# Property-based test of the transcript collector's core invariant (SOTA backlog #24):
#
#   every line that is complete in a watched file when a run commits is delivered to the
#   model exactly once across all committed runs — never lost, never duplicated.
#
# Each seed drives a random sequence of writer operations against a few watched transcript
# files, interleaved with collector runs:
#   append    1–5 complete lines (finishing any pending partial line first)
#   partial   write half a line with no newline (a session still being written)
#   truncate  empty the file in place (: > f), then optionally append straight away
#   rotate    move the file out of the glob and start a new one at the same path, often
#             larger than the old watermark
#   commit    run collect_all, count the delivered lines, apply the new watermarks
#   fail      run collect_all and throw it away with watermarks held (a failed run)
# The oracle only requires lines that were complete in a watched file at some committed run;
# lines destroyed by the writer before any run could see them are allowed to be missing,
# but no line may ever be delivered twice.
#
# Usage: test/prop/watermarks.sh [seeds] [steps]   (env PROP_SEEDS / PROP_STEPS / PROP_SEED)
# A failure prints the seed and the op log; rerun one seed with PROP_SEED=<n>.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
SEEDS="${1:-${PROP_SEEDS:-25}}"
STEPS="${2:-${PROP_STEPS:-40}}"
NFILES=3

TMP="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-prop.XXXXXX")"
[[ -n "${KEEP_TMP:-}" ]] || trap 'rm -rf "$TMP"' EXIT

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/redact.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/collect.sh"
collect_github() { :; }            # GitHub collection is out of scope here
write_context() { :; }             # needs a catalog manifest; irrelevant to watermarks

FIRST_RUN_LOOKBACK_HOURS=100000
MAX_FILE_KB=100000
MAX_BUNDLE_KB=100000
INCLUDE_PROJECTS=("*")
EXCLUDE_PROJECTS=()
COWORK_GLOBS=()
INCLUDE_TOOL_CALLS=true
LOG=/dev/null

line_json() {  # line_json <id> -> one transcript line, no newline
  printf '{"type":"user","cwd":"/p/prop","sessionId":"s","message":{"role":"user","content":"LWPROP-%06d marker text for line %d"}}' "$1" "$1"
}

run_seed() {
  local seed="$1" step op i f k id n cut
  local S="$TMP/s$seed"
  STATE_DIR="$S/state"; RUN_DIR="$STATE_DIR/run"; WATERMARKS="$STATE_DIR/watermarks.json"
  RULES_JSON=""
  mkdir -p "$STATE_DIR" "$S/projects/-p-prop"
  echo '{"files":{},"git":{}}' > "$WATERMARKS"
  CLAUDE_CODE_GLOBS=("$S/projects/*/*.jsonl")
  : > "$S/delivered"; : > "$S/required"; : > "$S/ops"
  local -a pending=()
  for (( i = 0; i < NFILES; i++ )); do pending[i]=""; : > "$S/projects/-p-prop/f$i.jsonl"; done
  id=0
  RANDOM="$seed"

  for (( step = 0; step < STEPS; step++ )); do
    i=$(( RANDOM % NFILES )); f="$S/projects/-p-prop/f$i.jsonl"
    op=$(( RANDOM % 100 ))
    if   (( op < 38 )); then op=append
    elif (( op < 48 )); then op=partial
    elif (( op < 56 )); then op=truncate
    elif (( op < 64 )); then op=rotate
    elif (( op < 92 )); then op=commit
    else op=fail; fi
    echo "$step $op f$i" >> "$S/ops"

    case "$op" in
      append|partial)
        if [[ -n "${pending[i]}" ]]; then printf '%s\n' "${pending[i]}" >> "$f"; pending[i]=""; fi
        if [[ "$op" == append ]]; then
          n=$(( RANDOM % 5 + 1 ))
          for (( k = 0; k < n; k++ )); do id=$((id + 1)); line_json "$id" >> "$f"; echo >> "$f"; done
        else
          id=$((id + 1)); local l; l="$(line_json "$id")"; cut=$(( ${#l} / 2 ))
          printf '%s' "${l:0:$cut}" >> "$f"; pending[i]="${l:$cut}"
        fi ;;
      truncate|rotate)
        if [[ "$op" == rotate ]]; then mv "$f" "$f.1"; fi
        : > "$f"; pending[i]=""
        # regrow straight away, often past the old watermark (the dangerous case)
        n=$(( RANDOM % 12 ))
        for (( k = 0; k < n; k++ )); do id=$((id + 1)); line_json "$id" >> "$f"; echo >> "$f"; done ;;
      commit|fail)
        rm -rf "$RUN_DIR"; mkdir -p "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git"
        if ! ( collect_all ) 2>>"$S/collector.log"; then
          echo "FAIL seed $seed: collector died at step $step" >&2; tail -5 "$S/collector.log" >&2; return 1
        fi
        if [[ "$op" == commit ]]; then
          # a line is required only if it is complete (newline-terminated) at this commit
          for (( k = 0; k < NFILES; k++ )); do
            { complete_lines "$S/projects/-p-prop/f$k.jsonl" | grep -o 'LWPROP-[0-9]*' || true; } >> "$S/required"
          done
          { find "$RUN_DIR/bundle/transcripts" -type f -exec cat {} + | grep -o 'LWPROP-[0-9]*' || true; } >> "$S/delivered"
          cp "$RUN_DIR/new-watermarks.json" "$WATERMARKS"
        fi ;;
    esac
  done

  local dups missing
  dups="$(sort "$S/delivered" | uniq -d | head -5 | tr '\n' ' ')"
  missing="$(comm -23 <(sort -u "$S/required") <(sort -u "$S/delivered") | head -5 | tr '\n' ' ')"
  if [[ -n "$dups" || -n "$missing" ]]; then
    echo "FAIL seed $seed: duplicated: [${dups% }] lost: [${missing% }]" >&2
    echo "  ops ($(wc -l < "$S/ops" | tr -d ' ')): $(tr '\n' ';' < "$S/ops")" >&2
    return 1
  fi
  PROP_LINES=$(( PROP_LINES + $(sort -u "$S/delivered" | wc -l | tr -d ' ') ))
  PROP_COMMITS=$(( PROP_COMMITS + $(grep -c ' commit ' "$S/ops" || true) ))
}

# complete_lines <file>: the file's newline-terminated lines only (drops a trailing partial)
complete_lines() {
  local f="$1" sz
  sz="$(file_size "$f")"
  [[ "$sz" -gt 0 ]] || return 0
  if [[ "$(tail -c 1 "$f" | od -An -c | tr -d ' ')" == '\n' ]]; then cat "$f"; else sed '$d' "$f"; fi
}

PROP_LINES=0; PROP_COMMITS=0; failed=0
if [[ -n "${PROP_SEED:-}" ]]; then set -- "$PROP_SEED"; else set -- $(seq 1 "$SEEDS"); fi
for s in "$@"; do run_seed "$s" || failed=$((failed + 1)); done
if [[ "$failed" -gt 0 ]]; then
  echo "watermark properties: $failed of $# seeds FAILED ($STEPS steps each)" >&2
  exit 1
fi
echo "watermark properties: $# seeds x $STEPS steps, $PROP_COMMITS committed runs, $PROP_LINES lines each delivered exactly once"
