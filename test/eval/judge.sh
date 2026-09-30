#!/usr/bin/env bash
# LLM-as-judge page quality eval (SOTA backlog #27). Opt-in: it calls a real model and costs
# about $0.01-0.03 per page on Haiku. The golden eval checks shape and cost; this checks
# whether the pages are any good, against a fixed rubric (test/eval/judge/rubric.md):
#   faithfulness · specificity · reusability · clarity, each 1-5, plus unsupported claims.
#
#   test/eval/judge.sh                       judge the golden pages against the golden source
#   test/eval/judge.sh --pages <p.json> --source <file>...
#                                            judge other pages (a writer-pages.json array or a
#                                            recorded extract.json), e.g. from a --live eval
#   test/eval/judge.sh --record              judge the golden and store the scores as baseline
#   test/eval/judge.sh --calibrate           judge the golden page AND a copy with 3 invented
#                                            facts; passes only if the judge catches the fakes
#                                            (faithfulness >= 2 points lower, fakes listed)
#
# Fails when a page scores faithfulness < JUDGE_MIN_FAITHFULNESS (4; calibration: a page with 4
# planted claims scored 3), or when a dimension's
# mean falls more than JUDGE_TOLERANCE (0.75) below the recorded baseline.
# Env: CLAUDE_BIN, JUDGE_MODEL (haiku), JUDGE_BUDGET_USD (0.10 per page).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GOLD="$HERE/fixtures/day1/recorded"
BASELINE="$GOLD/judge-baseline.json"
PAGES="$GOLD/extract.json"
SOURCES=("$GOLD"/bundle-*.txt)
RECORD=false; CALIBRATE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --pages)  PAGES="$2"; shift 2 ;;
    --source) SOURCES=(); shift; while [[ $# -gt 0 && "$1" != --* ]]; do SOURCES+=("$1"); shift; done ;;
    --record) RECORD=true; shift ;;
    --calibrate) CALIBRATE=true; shift ;;
    *) echo "usage: $0 [--pages <json>] [--source <file>...] [--record]" >&2; exit 2 ;;
  esac
done
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -x "$CLAUDE_BIN" ]] || { echo "FAIL [judge]: claude CLI not found (set CLAUDE_BIN)" >&2; exit 1; }
MODEL="${JUDGE_MODEL:-haiku}"; BUDGET="${JUDGE_BUDGET_USD:-0.10}"
MINF="${JUDGE_MIN_FAITHFULNESS:-4}"; TOL="${JUDGE_TOLERANCE:-0.75}"

W="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-judge.XXXXXX")"
trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL [judge]: $*" >&2; exit 1; }

jq -c '(.structured_output.pages // .pages // .)[]' "$PAGES" > "$W/pages.jsonl"
[[ -s "$W/pages.jsonl" ]] || fail "no pages in $PAGES"
if $CALIBRATE; then
  # same page with three plausible, specific, UNSUPPORTED claims planted in it
  head -1 "$W/pages.jsonl" > "$W/one.jsonl"
  jq -c '.slug += "-planted" | .body_html += "<h2>Also changed</h2><p>We also moved the nightly job to <code>systemd-timer loopwatch-nightly.timer</code> with <code>RandomizedDelaySec=45min</code>, which cut the monthly bill from $212 to $38.</p><p>Run <code>loopwatch --purge-cache --since 90d</code> after upgrading, or the watermarks from v0.1 are replayed.</p>"' \
    "$W/one.jsonl" > "$W/planted.jsonl"
  cat "$W/one.jsonl" "$W/planted.jsonl" > "$W/pages.jsonl"
fi
{ for f in "${SOURCES[@]}"; do echo "<source file=\"${f##*/}\">"; cat "$f"; echo "</source>"; done; } > "$W/source.txt"

: > "$W/scores.jsonl"
i=0
while IFS= read -r page; do
  i=$((i + 1))
  { echo "<source-bundle>"; cat "$W/source.txt"; echo "</source-bundle>"
    echo "<page>"; jq -r '"TITLE: " + .title + "\nSUMMARY: " + (.summary // "") + "\n\n" + .body_html' <<< "$page"; echo "</page>"
  } > "$W/in-$i.txt"
  ( cd "$W" && MAX_THINKING_TOKENS=0 "$CLAUDE_BIN" -p --model "$MODEL" --tools "" --strict-mcp-config \
      --no-session-persistence --output-format json --max-budget-usd "$BUDGET" \
      --system-prompt "$(cat "$HERE/judge/rubric.md")" --json-schema "$(cat "$HERE/judge/schema.json")" \
      < "$W/in-$i.txt" > "$W/out-$i.json" 2> "$W/err-$i.txt" ) || true
  jq -e '.structured_output | objects | .faithfulness' "$W/out-$i.json" >/dev/null 2>&1 \
    || fail "page $i: no structured verdict ($(jq -r '.subtype // .result // empty' "$W/out-$i.json" 2>/dev/null | head -c 200; head -c 200 "$W/err-$i.txt"))"
  jq -c --argjson p "$page" '.structured_output + {slug: $p.slug, cost_usd: (.total_cost_usd // 0)}' "$W/out-$i.json" >> "$W/scores.jsonl"
  jq -r '"  \(.slug): faithfulness \(.faithfulness) · specificity \(.specificity) · reusability \(.reusability) · clarity \(.clarity) · $\(.cost_usd)\n    \(.verdict)"
         + (if (.unsupported | length) > 0 then "\n    unsupported: " + (.unsupported | join(" | ")) else "" end)' <(tail -1 "$W/scores.jsonl")
done < "$W/pages.jsonl"

jq -s '. as $s | {pages: length, cost_usd: (map(.cost_usd) | add * 10000 | round / 10000),
        mean: (reduce ("faithfulness","specificity","reusability","clarity") as $d ({}; .[$d] = (($s | map(.[$d]) | add) / ($s | length) * 100 | round / 100))),
        min_faithfulness: (map(.faithfulness) | min)}' "$W/scores.jsonl" > "$W/summary.json"
echo "  mean: $(jq -c '.mean' "$W/summary.json") over $(jq .pages "$W/summary.json") page(s), cost \$$(jq '.cost_usd' "$W/summary.json")"

if $CALIBRATE; then
  jq -s -e '.[0].faithfulness - .[1].faithfulness >= 2 and (.[1].unsupported | length) >= 2' "$W/scores.jsonl" >/dev/null \
    || fail "judge did not catch the planted claims: faithfulness $(jq -s -c 'map(.faithfulness)' "$W/scores.jsonl"), unsupported on the planted copy: $(jq -s '.[1].unsupported | length' "$W/scores.jsonl")"
  echo "PASS — judge calibrated: planted page faithfulness $(jq -s '.[1].faithfulness' "$W/scores.jsonl") vs $(jq -s '.[0].faithfulness' "$W/scores.jsonl"), $(jq -s '.[1].unsupported | length' "$W/scores.jsonl") unsupported claims listed"
  exit 0
fi
if $RECORD; then
  jq --arg m "$MODEL" '. + {model: $m, recorded: (now | todate)}' "$W/summary.json" > "$BASELINE"
  echo "PASS — judge baseline recorded ($BASELINE)"; exit 0
fi
jq -e --argjson m "$MINF" '.min_faithfulness >= $m' "$W/summary.json" >/dev/null \
  || fail "a page scored faithfulness $(jq .min_faithfulness "$W/summary.json") (< $MINF): it states things its source does not"
if [[ -f "$BASELINE" ]]; then
  drops="$(jq -r --slurpfile b "$BASELINE" --argjson t "$TOL" '
    .mean | to_entries[] | select(.value < ($b[0].mean[.key] - $t))
    | "\(.key) \(.value) vs baseline \($b[0].mean[.key])"' "$W/summary.json")"
  [[ -z "$drops" ]] || fail "quality regressed beyond ${TOL}: $drops"
  echo "PASS — judge (within $TOL of baseline $(jq -c '.mean' "$BASELINE"))"
else
  echo "PASS — judge (no baseline yet; record one with --record)"
fi
