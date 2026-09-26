#!/usr/bin/env bash
# loopwatch lib — two-tier extraction (sourced; do not execute). R-3.
#
#   Stage A  triage   TRIAGE_MODEL (haiku)  read-only tools, reads the whole bundle,
#                     returns digest + 0..N candidates with evidence line ranges
#   Stage B  writing  MODEL (sonnet)        runs ONLY if candidates is non-empty, and
#                     sees only excerpts of the cited lines (the bundle is moved out)
#
# Produces $RUN_DIR/run-meta.json in the v0.1 publisher's shape.

# pull the JSON object out of the triage result text (tolerates code fences / preamble)
parse_triage() {
  jq -e '
    (.result // "") as $r
    | ($r | capture("(?s)(?<j>\\{.*\\})").j | fromjson)
    | select(type == "object"
             and (.digest_summary | type == "string")
             and ((.highlights // []) | type == "array")
             and (.candidates | type == "array"))
    | .highlights = ((.highlights // []) | map(select(type == "string")) | .[:8])
    | .candidates = (.candidates
        | map(select(type == "object" and (.id | type == "string") and (.id | test("^[a-z0-9-]{1,24}$"))
                     and (.title | type == "string") and ((.evidence // []) | type == "array")))
        | unique_by(.id))' "$RUN_DIR/triage.json" 2>/dev/null
}

# build_excerpts: writes excerpts/<id>.txt from each candidate's evidence ranges.
# Evidence must name a real file under bundle/; ranges are clamped and padded.
build_excerpts() {
  local cands="$RUN_DIR/candidates.json" id file a b n total=0 cap_each cap_total out hdr
  cap_each=$(( EXCERPT_MAX_KB * 1024 ))
  cap_total=$(( EXCERPT_TOTAL_KB * 1024 ))
  mkdir -p "$RUN_DIR/excerpts"
  while IFS= read -r id; do
    out="$RUN_DIR/excerpts/$id.txt"
    : > "$out"
    while IFS=$'\t' read -r file a b; do
      case "$file" in
        bundle/transcripts/*|bundle/git/*) ;;
        *) log "triage: ignored evidence outside the bundle for $id"; continue ;;
      esac
      case "$file" in *..*) log "triage: ignored evidence path with '..' for $id"; continue ;; esac
      [[ -f "$RUN_DIR/$file" ]] || { log "triage: ignored evidence for missing file ($id)"; continue; }
      [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ ]] || continue
      [[ "$a" -ge 1 ]] || a=1
      [[ "$b" -ge "$a" ]] || b="$a"
      a=$(( a > EXCERPT_CONTEXT_LINES ? a - EXCERPT_CONTEXT_LINES : 1 ))
      b=$(( b + EXCERPT_CONTEXT_LINES ))
      hdr="$(head -n 1 "$RUN_DIR/$file")"
      { echo "$hdr"; echo "--- lines $a-$b of $(basename "$file") ---"; sed -n "${a},${b}p" "$RUN_DIR/$file"; echo; } >> "$out"
    done < <(jq -r --arg id "$id" '.candidates[] | select(.id == $id) | (.evidence // [])[:4][]
                                   | [(.file // ""), ((.start_line // 0) | tostring), ((.end_line // 0) | tostring)] | @tsv' "$cands")
    if [[ "$(file_size "$out")" -gt "$cap_each" ]]; then
      head -c "$cap_each" "$out" > "$out.tmp" && mv "$out.tmp" "$out"
    fi
    n="$(file_size "$out")"
    if [[ "$n" -eq 0 ]]; then
      rm -f "$out"
      log "triage: candidate $id has no usable evidence — dropped"
      continue
    fi
    if [[ $(( total + n )) -gt "$cap_total" ]]; then
      rm -f "$out"
      log "triage: excerpt budget (${EXCERPT_TOTAL_KB}KB) reached — candidate $id dropped"
      continue
    fi
    total=$(( total + n ))
  done < <(jq -r '.candidates[].id' "$cands")
  # keep only candidates that still have an excerpt
  local keep
  keep="$(ls "$RUN_DIR/excerpts" 2>/dev/null | sed 's/\.txt$//' | jq -R . | jq -sc .)"
  jq --argjson keep "$keep" '.candidates |= map(select(.id as $i | $keep | index($i)))' "$cands" > "$cands.tmp" \
    && mv "$cands.tmp" "$cands"
}

# stage B hides the bundle so the writer can only work from the cited excerpts
BUNDLE_HELD=""
hold_bundle()    { BUNDLE_HELD="$STATE_DIR/.bundle-held"; rm -rf "$BUNDLE_HELD"; mv "$RUN_DIR/bundle" "$BUNDLE_HELD"; }
restore_bundle() { if [[ -n "$BUNDLE_HELD" && -d "$BUNDLE_HELD" ]]; then rm -rf "$RUN_DIR/bundle"; mv "$BUNDLE_HELD" "$RUN_DIR/bundle"; fi; BUNDLE_HELD=""; }

usage_cost() { jq -s 'map(.cost_usd) | add // 0' "$RUN_DIR/usage.jsonl"; }

# run_extraction: stage A, then stage B if warranted. Leaves run-meta.json.
run_extraction() {
  local budget_a budget_b n_cand spent
  budget_a="$(jq -n --argjson a "$TRIAGE_BUDGET_USD" --argjson t "$BUDGET_USD" '[$a, $t] | min')"

  log "stage A triage: model=$TRIAGE_MODEL budget=\$$budget_a"
  if ! run_claude triage "$TRIAGE_MODEL" "$ROOT_DIR/prompts/triage.md" "Read,Glob,Grep" "$TRIAGE_MAX_TURNS" "$budget_a"; then
    case "$CLAUDE_LAST_SUBTYPE" in
      *budget*) DIE_REASON=budget_exceeded; die "triage hit its \$$budget_a budget cap (watermarks not advanced)" ;;
      *)        DIE_REASON=claude_error;    die "triage failed (subtype=$CLAUDE_LAST_SUBTYPE) — see triage.json/triage.err" ;;
    esac
  fi
  parse_triage > "$RUN_DIR/candidates.json" \
    || { DIE_REASON=triage_parse_error; die "triage output is not the expected JSON object (see triage.json)"; }
  jq --argjson max "$MAX_CANDIDATES" '.candidates |= .[:$max]' "$RUN_DIR/candidates.json" > "$RUN_DIR/c.tmp" \
    && mv "$RUN_DIR/c.tmp" "$RUN_DIR/candidates.json"
  build_excerpts
  n_cand="$(jq '.candidates | length' "$RUN_DIR/candidates.json")"
  spent="$(usage_cost)"
  log "stage A done: $n_cand candidate(s), \$$spent"

  # digest skeleton from triage; stage B only contributes pages
  jq --arg d "$RUN_DATE" '{run_date: $d, digest_summary, highlights, pages: []}' "$RUN_DIR/candidates.json" > "$RUN_DIR/triage-meta.json"

  if [[ "$n_cand" -eq 0 ]]; then
    log "stage B skipped: triage found nothing page-worthy"
    STAGE_B_SKIP="no_candidates"
    cp "$RUN_DIR/triage-meta.json" "$RUN_DIR/run-meta.json"
    return 0
  fi

  budget_b="$(jq -n --argjson t "$BUDGET_USD" --argjson s "$spent" '($t - $s) * 100 | floor / 100')"
  if jq -e --argjson b "$budget_b" -n '$b < 0.05' >/dev/null; then
    log "stage B skipped: only \$$budget_b of the \$$BUDGET_USD run budget left"
    STAGE_B_SKIP="budget"
    cp "$RUN_DIR/triage-meta.json" "$RUN_DIR/run-meta.json"
    return 0
  fi

  cp "$RUN_DIR/bundle/context.json" "$RUN_DIR/context.json"
  hold_bundle
  log "stage B writing: model=$MODEL budget=\$$budget_b"
  if ! run_claude extract "$MODEL" "$ROOT_DIR/prompts/extract.md" "Read,Write,Glob,Grep" "$MAX_TURNS" "$budget_b"; then
    restore_bundle
    case "$CLAUDE_LAST_SUBTYPE" in
      *budget*) DIE_REASON=budget_exceeded; die "writing stage hit its \$$budget_b budget cap (watermarks not advanced)" ;;
      *)        DIE_REASON=claude_error;    die "writing stage failed (subtype=$CLAUDE_LAST_SUBTYPE) — see extract.json/extract.err" ;;
    esac
  fi
  restore_bundle

  if [[ ! -f "$RUN_DIR/run-meta.json" ]] || ! jq -e '.pages | type == "array"' "$RUN_DIR/run-meta.json" >/dev/null 2>&1; then
    DIE_REASON=no_meta; die "writing stage produced no valid run-meta.json"
  fi
  # the digest always comes from triage
  jq --slurpfile t "$RUN_DIR/triage-meta.json" \
    '.digest_summary = $t[0].digest_summary | .highlights = $t[0].highlights | .run_date = $t[0].run_date' \
    "$RUN_DIR/run-meta.json" > "$RUN_DIR/m.tmp" && mv "$RUN_DIR/m.tmp" "$RUN_DIR/run-meta.json"
}
