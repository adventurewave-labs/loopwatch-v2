#!/usr/bin/env bash
# loopwatch lib — two-tier extraction (sourced; do not execute). R-3.
#
#   Stage A  triage   TRIAGE_MODEL (haiku)  gets the whole bundle (line-numbered) on stdin,
#                     returns digest + 0..N candidates with evidence line ranges
#   Stage B  writing  MODEL (sonnet)        runs ONLY if candidates is non-empty, and gets
#                     ONLY the cited excerpts on stdin; returns page bodies as JSON
#
# Both calls are tool-free and schema-constrained (lib/common.sh run_claude). Page HTML
# is rendered here from the returned body, never written by the model.
# Produces $RUN_DIR/run-meta.json + $RUN_DIR/pages/*.html in the publisher's shape.

# Spotlighting: every piece of collected data is fenced in tags the system prompt names
# as data. Inside the data, ANY opening or closing form of a fence tag (any case, spaces,
# attributes: "</FILE >", "<Excerpt id=...>") has its "<" turned into "&lt;", so content can
# neither close a fence nor forge a new block. Case-folding is spelled out in bracket
# classes because BSD sed has no I flag.
FENCE_TAGS='[Ff][Ii][Ll][Ee]|[Ee][Xx][Cc][Ee][Rr][Pp][Tt]|[Cc][Oo][Nn][Tt][Ee][Xx][Tt]|[Cc][Aa][Nn][Dd][Ii][Dd][Aa][Tt][Ee][Ss]'
fence() { sed -E "s#<([[:space:]]*/?[[:space:]]*)($FENCE_TAGS)([^A-Za-z0-9_-]|\$)#\\&lt;\\1\\2\\3#g"; }

build_triage_input() {
  local f rel
  {
    echo "<context>"; jq . "$RUN_DIR/bundle/context.json" | fence; echo "</context>"
    while IFS= read -r f; do
      rel="${f#"$RUN_DIR"/}"
      echo "<file path=\"$rel\">"
      awk '{ printf "%d: %s\n", NR, $0 }' "$f" | fence
      echo "</file>"
    done < <(find "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" -type f 2>/dev/null | sort)
  } > "$RUN_DIR/triage-input.txt"
  # Per-run schema: evidence.file must be one of THIS run's paths (enum), so the model
  # cannot cite a path it merely saw mentioned inside a transcript.
  find "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" -type f 2>/dev/null | sort \
    | while IFS= read -r f; do printf '%s\n' "${f#"$RUN_DIR"/}"; done \
    | jq -R . | jq -s . > "$RUN_DIR/bundle-paths.json"
  jq --slurpfile p "$RUN_DIR/bundle-paths.json" \
    '.properties.candidates.items.properties.evidence.items.properties.file.enum = $p[0]' \
    "$ROOT_DIR/schemas/triage.schema.json" > "$RUN_DIR/triage.schema.json"
}

build_writer_input() {
  local f
  {
    echo "<context>"; jq . "$RUN_DIR/bundle/context.json" | fence; echo "</context>"
    echo "<candidates>"; jq '.candidates' "$RUN_DIR/candidates.json" | fence; echo "</candidates>"
    for f in "$RUN_DIR"/excerpts/*.txt; do
      [[ -f "$f" ]] || continue
      echo "<excerpt id=\"$(basename "$f" .txt)\">"; fence < "$f"; echo "</excerpt>"
    done
  } > "$RUN_DIR/writer-input.txt"
}

# BODY_GATE_JQ: jq defs used by the markup allowlist (render_pages) and the fuzz harness.
BODY_GATE_JQ='def body_ok: [scan("<[A-Za-z/!?][^<>]*>?")]
  | all(test("^</?(h2|h3|h4|p|ul|ol|li|pre|code|strong|em|b|i|table|thead|tbody|tr|th|td|blockquote)>$|^<(br|hr) ?/?>$"));'

# render_page_files <pages.json>: fixed skeleton + escaped metadata + body -> pages/<slug>.html
render_page_files() {
  local slug
  mkdir -p "$RUN_DIR/pages"
  jq -c '.[]' "$1" \
  | while IFS= read -r row; do
      slug="$(jq -r '.slug' <<< "$row")"
      jq -r --arg date "$RUN_DATE" '
        (.title // "" | tostring | @html) as $t
        | "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n<title>" + $t + "</title>\n<style>\n"
          + "  :root { color-scheme: dark; }\n  body { margin:0; background:#0f1115; color:#d7dae0; font:16px/1.6 -apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif; }\n"
          + "  main { max-width:780px; margin:0 auto; padding:48px 24px; }\n  h1 { font-size:1.6rem; line-height:1.3; margin:0 0 8px; }\n"
          + "  .meta { color:#8b93a7; font-size:.85rem; margin-bottom:32px; }\n  h2 { font-size:1.15rem; margin-top:36px; border-bottom:1px solid #232838; padding-bottom:6px; }\n"
          + "  code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size:.9em; background:#161a22; padding:2px 5px; border-radius:4px; }\n"
          + "  pre { background:#161a22; border:1px solid #232838; border-radius:8px; padding:16px; overflow-x:auto; }\n  pre code { background:none; padding:0; }\n"
          + "  table { border-collapse:collapse; } td, th { border:1px solid #232838; padding:4px 8px; }\n"
          + "  ul, ol { padding-left:1.2em; }\n  footer { margin-top:48px; padding-top:16px; border-top:1px solid #232838; color:#8b93a7; font-size:.8rem; }\n"
          + "</style>\n</head>\n<body><main>\n<h1>" + $t + "</h1>\n"
          + "<div class=\"meta\">" + ($date | @html) + " · " + (.category // "" | tostring | @html) + " · " + (.source // "" | tostring | @html) + "</div>\n"
          + (.body_html // "") + "\n"
          + "<footer>" + ($date | @html) + " · " + (.source // "" | tostring | @html) + " · generated by loopwatch</footer>\n</main></body>\n</html>"
      ' <<< "$row" > "$RUN_DIR/pages/$slug.html"
    done
}

# render_pages: structured page bodies -> pages/<slug>.html (fixed skeleton, escaped
# metadata) + run-meta.json. The validator and post-scan still run on the result.
render_pages() {
  local slug
  mkdir -p "$RUN_DIR/pages"
  # One well-formed page per slug, decided once, so the HTML files and run-meta can never
  # describe different pages: objects only, string body_html, valid slug, first slug wins.
  # A malformed page is dropped on its own instead of aborting the run.
  jq -c '[(.structured_output.pages // [])[]
          | select(type == "object" and (.body_html | type) == "string"
                   and ((.slug // "") | type == "string" and test("^[a-z0-9][a-z0-9-]{2,79}$")))]
         | reduce .[] as $p ([]; if any(.[]; .slug == $p.slug) then . else . + [$p] end)' \
     "$RUN_DIR/extract.json" > "$RUN_DIR/writer-pages.json" 2>/dev/null || echo '[]' > "$RUN_DIR/writer-pages.json"
  local raw kept
  raw="$(jq '(.structured_output.pages // []) | length' "$RUN_DIR/extract.json" 2>/dev/null || echo 0)"
  kept="$(jq 'length' "$RUN_DIR/writer-pages.json")"
  [[ "$raw" == "$kept" ]] || log "writer: dropped $(( raw - kept )) malformed or duplicate-slug page(s)"
  # Markup allowlist (primary control): the body may only use the bare tags the prompt
  # allows, with NO attributes, and every other "<" that could open a tag must be escaped.
  # Everything the blocklist validator (html_problem) looks for becomes impossible by
  # construction; html_problem still runs on the rendered file as a second, independent layer.
  local rejected
  rejected="$(jq -r "$BODY_GATE_JQ"' .[] | select(.body_html | body_ok | not) | .slug' "$RUN_DIR/writer-pages.json")"
  if [[ -n "$rejected" ]]; then
    while IFS= read -r slug; do log "validator: dropped page $slug: body markup outside the allowlist (tags/attributes)"; done <<< "$rejected"
    VALIDATOR_DROPS=$(( ${VALIDATOR_DROPS:-0} + $(printf '%s\n' "$rejected" | wc -l) ))
    jq "$BODY_GATE_JQ"' map(select(.body_html | body_ok))' "$RUN_DIR/writer-pages.json" > "$RUN_DIR/wp.tmp" \
      && mv "$RUN_DIR/wp.tmp" "$RUN_DIR/writer-pages.json"
  fi
  render_page_files "$RUN_DIR/writer-pages.json"
  jq --slurpfile t "$RUN_DIR/triage-meta.json" '
    {run_date: $t[0].run_date, digest_summary: $t[0].digest_summary, highlights: $t[0].highlights,
     pages: [.[] | {candidate_id, slug, title, category, tags: (.tags // []), summary, source,
                    file: ("pages/" + .slug + ".html")}]}' \
    "$RUN_DIR/writer-pages.json" > "$RUN_DIR/run-meta.json"
}

# triage result: .structured_output (schema-enforced); a JSON object in .result is
# accepted as a fallback. Shape is re-validated either way.
parse_triage() {
  jq -e '
    (.structured_output // ((.result // "") | capture("(?s)(?<j>\\{.*\\})").j | fromjson))
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

usage_cost() { jq -s 'map(.cost_usd) | add // 0' "$RUN_DIR/usage.jsonl"; }

# run_extraction: stage A, then stage B if warranted. Leaves run-meta.json.
run_extraction() {
  local budget_a budget_b n_cand spent
  budget_a="$(jq -n --argjson a "$TRIAGE_BUDGET_USD" --argjson t "$BUDGET_USD" '[$a, $t] | min')"

  build_triage_input
  local leak
  if ! leak="$(input_scan "$RUN_DIR/triage-input.txt")"; then
    DIE_REASON=input_leak; die "triage input matches redaction rules ($leak): unscrubbed data would reach the model"
  fi
  log "stage A triage: model=$TRIAGE_MODEL budget=\$$budget_a input=$(( $(file_size "$RUN_DIR/triage-input.txt") / 1024 ))KB"
  if ! call_stage triage "$TRIAGE_MODEL" "${TRIAGE_FALLBACK_MODEL:-}" "$ROOT_DIR/prompts/triage.md" "$RUN_DIR/triage-input.txt" "$RUN_DIR/triage.schema.json" "$budget_a"; then
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

  build_writer_input
  if ! leak="$(input_scan "$RUN_DIR/writer-input.txt")"; then
    DIE_REASON=input_leak; die "writer input matches redaction rules ($leak): unscrubbed data would reach the model"
  fi
  log "stage B writing: model=$MODEL budget=\$$budget_b input=$(( $(file_size "$RUN_DIR/writer-input.txt") / 1024 ))KB"
  if ! call_stage extract "$MODEL" "${FALLBACK_MODEL:-}" "$ROOT_DIR/prompts/extract.md" "$RUN_DIR/writer-input.txt" "$ROOT_DIR/schemas/pages.schema.json" "$budget_b"; then
    case "$CLAUDE_LAST_SUBTYPE" in
      *budget*) DIE_REASON=budget_exceeded; die "writing stage hit its \$$budget_b budget cap (watermarks not advanced)" ;;
      *)        DIE_REASON=claude_error;    die "writing stage failed (subtype=$CLAUDE_LAST_SUBTYPE) — see extract.json/extract.err" ;;
    esac
  fi
  jq -e '.structured_output.pages | type == "array"' "$RUN_DIR/extract.json" >/dev/null 2>&1 \
    || { DIE_REASON=no_meta; die "writing stage returned no structured pages (see extract.json)"; }
  render_pages
}
