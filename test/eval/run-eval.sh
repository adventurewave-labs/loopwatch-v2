#!/usr/bin/env bash
# loopwatch eval harness.
#
#   test/eval/run-eval.sh            OFFLINE (default, runs in CI): feeds a frozen sample day through
#                                    the real pipeline, answering each model call with the RECORDED
#                                    real output from claude 2.1.283. Asserts golden behaviour: the
#                                    bundle is rebuilt byte-for-byte, calls are tool-free and
#                                    schema-pinned, and pages, drops, digest and ledger cost all match.
#   test/eval/run-eval.sh --live     LIVE (opt-in, costs money, about $0.15-0.40): same sample day,
#                                    real models. Reports pages/cost/latency against the golden run and
#                                    fails if quality collapses (0 pages) or cost exceeds 2x golden.
#                                    Use it before merging prompt or schema changes.
#   test/eval/run-eval.sh --record   LIVE run that then REPLACES the golden (recorded outputs,
#                                    bundle and PROMPT_VERSION). Use after a --live run you accept.
#   test/eval/judge.sh               LIVE page-QUALITY eval (opt-in, Haiku, ~$0.04 per page): rubric
#                                    scores against judge-baseline.json; --calibrate proves the judge
#                                    catches planted claims.
#
# Provenance: recorded/PROMPT_VERSION is the prompt_version (hash of prompts + schemas) the
# golden was recorded under. Offline mode fails when they drift, so a prompt edit can't pass CI
# on a golden that no longer describes it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HERE/../.." && pwd)"
FIX="$HERE/fixtures/day1"
MODE="${1:-offline}"
LW_BASH="${LW_BASH:-$BASH}"

W="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-eval.XXXXXX")"
[[ -n "${LW_EVAL_KEEP:-}" ]] && echo "  (keeping $W)" || trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL [eval $MODE]: $*" >&2; [[ -f "$W/run.log" ]] && tail -20 "$W/run.log" >&2; exit 1; }
ok()   { echo "  ok: $*"; }

export HOME="$W/home"
unset XDG_CONFIG_HOME XDG_STATE_HOME LOOPWATCH_CONF 2>/dev/null || true
STATE="$HOME/.local/state/loopwatch"
mkdir -p "$HOME/.config/loopwatch" "$HOME/.claude/projects"
cp -R "$FIX/transcripts/." "$HOME/.claude/projects/"
: > "$HOME/.config/loopwatch/redact.list"; chmod 600 "$HOME/.config/loopwatch/redact.list"

# catalog remote seeded from site/
BARE="$W/catalog.git"; git init -q --bare "$BARE"; git -C "$BARE" symbolic-ref HEAD refs/heads/main
mkdir -p "$W/seed"; cp -R "$SRC_ROOT/site" "$W/seed/site"
git -C "$W/seed" init -q
git -C "$W/seed" -c user.name=eval -c user.email=eval@test add -A
git -C "$W/seed" -c user.name=eval -c user.email=eval@test commit -qm seed
git -C "$W/seed" push -q "$BARE" HEAD:refs/heads/main
export STUB_GH_REMOTE="$BARE" STUB_GH_STATE="$W/gh" STUB_GH_CALLS="$W/gh-calls.log"; mkdir -p "$W/gh"

if [[ "$MODE" == "--live" || "$MODE" == "--record" ]]; then
  CLAUDE_BIN="$(command -v claude)" || fail "claude CLI not found"
else
  CLAUDE_BIN="$HERE/replay-claude"
  export REPLAY_DIR="$FIX/recorded" REPLAY_OUT="$W/replay"
fi
cat > "$HOME/.config/loopwatch/loopwatch.conf" <<EOF
CLAUDE_CODE_GLOBS=("\$HOME/.claude/projects/*/*.jsonl")
COWORK_GLOBS=()
GITHUB_SCOPES=()
INCLUDE_PROJECTS=("*")
CLAUDE_BIN="$CLAUDE_BIN"
GH_BIN="$SRC_ROOT/test/stubs/gh"
CATALOG_REPO="eval/catalog"
SITE_VISIBILITY=protected
SITE_URL=""
FIRST_RUN_LOOKBACK_HOURS=999999
EOF
touch "$HOME/.claude/projects"/*/*.jsonl

echo "— eval ($MODE): frozen sample day through the full pipeline (dry run) —"
start=$(date +%s)
"$LW_BASH" "$SRC_ROOT/bin/loopwatch-run.sh" --dry-run 2> "$W/run.log" || fail "pipeline failed"
secs=$(( $(date +%s) - start ))
L="$(tail -n 1 "$STATE/runs.jsonl")"
RUN="$STATE/run"
GOLD_COST="$(jq -s 'map(.total_cost_usd) | add' "$FIX/recorded/triage.json" "$FIX/recorded/extract.json")"
GOLD_PAGES="$(jq '.structured_output.pages | length' "$FIX/recorded/extract.json")"

PV_NOW="$(bash -c "ROOT_DIR='$SRC_ROOT'; source '$SRC_ROOT/lib/common.sh'; prompt_version '$SRC_ROOT'")"
PV_GOLD="$(cat "$FIX/recorded/PROMPT_VERSION" 2>/dev/null || echo none)"
[[ "$(jq -r '.prompt_version' <<< "$L")" == "$PV_NOW" ]] || fail "ledger prompt_version $(jq -r .prompt_version <<< "$L") != $PV_NOW"

if [[ "$MODE" == "offline" ]]; then
  [[ "$PV_NOW" == "$PV_GOLD" ]] || fail "prompts/schemas changed (prompt_version $PV_NOW) but the golden was recorded under $PV_GOLD.
    Check the change with:  test/eval/run-eval.sh --live
    then accept it with:    test/eval/run-eval.sh --record"
  ok "golden recorded under the current prompt_version ($PV_NOW)"
  cmp -s "$RUN/bundle/transcripts/claude-code-1.txt" "$FIX/recorded/bundle-1.txt" || fail "collector no longer rebuilds bundle-1 byte-for-byte (filter/scrub regression): $(diff "$RUN/bundle/transcripts/claude-code-1.txt" "$FIX/recorded/bundle-1.txt" | head -5)"
  cmp -s "$RUN/bundle/transcripts/claude-code-2.txt" "$FIX/recorded/bundle-2.txt" || fail "collector no longer rebuilds bundle-2 byte-for-byte"
  ok "collector rebuilds the recorded bundle byte-for-byte"
  [[ "$(cat "$REPLAY_OUT/triage-tools.txt")" == "" && "$(cat "$REPLAY_OUT/extract-tools.txt")" == "" ]] || fail "calls must be tool-free"
  jq -e '.properties.candidates.items.properties.evidence.items.properties.file.enum
         == ["bundle/transcripts/claude-code-1.txt","bundle/transcripts/claude-code-2.txt"]' "$REPLAY_OUT/triage-schema.json" >/dev/null \
    || fail "triage schema must pin evidence files"
  jq -e '.properties.pages.items.required | index("body_html")' "$REPLAY_OUT/extract-schema.json" >/dev/null || fail "writer schema"
  if grep -q '<file path=' "$REPLAY_OUT/extract-input.txt"; then fail "writer input contains the bundle"; fi
  ok "both calls tool-free; triage schema pinned to the 2 real paths; writer saw excerpts only"
  want="$(jq -c '[.structured_output.pages[].slug] | sort' "$FIX/recorded/extract.json")"
  got="$(jq -c '[.pages[].slug] | sort' "$RUN/run-meta.json")"
  [[ "$got" == "$want" ]] || fail "pages differ: got $got want $want"
  for slug in $(jq -r '.pages[].slug' "$RUN/run-meta.json"); do
    prob="$(bash -c "source '$SRC_ROOT/lib/publish.sh'; html_problem '$RUN/pages/$slug.html'")" || fail "validator could not run on $slug"
    [[ -z "$prob" ]] || fail "golden page now fails the validator: $slug ($prob)"
  done
  jq -e --argjson c "$GOLD_COST" --argjson gp "$GOLD_PAGES" '.validator_drops == 0 and .postscan_drops == 0 and .pages == $gp
        and .model == "haiku+sonnet" and ((.cost_usd - $c) | fabs) < 0.000001' <<< "$L" >/dev/null || fail "ledger differs from golden: $L"
  jq -e --slurpfile t "$FIX/recorded/triage.json" '.digest_summary == $t[0].structured_output.digest_summary' "$RUN/run-meta.json" >/dev/null || fail "digest differs"
  ok "$GOLD_PAGES golden page(s) rendered and validator-clean; 0 drops; digest identical; ledger cost \$$GOLD_COST exact"
  echo "PASS — offline eval"
else
  echo "  prompt_version: $PV_NOW (golden: $PV_GOLD)"
  pages="$(jq '.pages' <<< "$L")"; cost="$(jq '.cost_usd' <<< "$L")"
  printf '  live: %s page(s), $%s, %ss   |   golden: %s page(s), $%s\n' "$pages" "$cost" "$secs" "$GOLD_PAGES" "$GOLD_COST"
  jq -r '.pages[] | "    - [\(.category)] \(.title)"' "$RUN/run-meta.json"
  [[ "$pages" -ge 1 ]] || fail "quality collapse: 0 pages on a day that produced $GOLD_PAGES"
  # cost gate normalised for how much work the day produced: triage cost (same input every
  # time) and writer cost PER PAGE must each stay within 2x the golden. A raw total would
  # flag a 3-page day against a 1-page golden as a "regression".
  GT="$(jq '.total_cost_usd' "$FIX/recorded/triage.json")"
  GW="$(jq --argjson p "$GOLD_PAGES" '.total_cost_usd / ([$p, 1] | max)' "$FIX/recorded/extract.json")"
  LT="$(jq '[.stages[] | select(.stage == "triage") | .cost_usd] | add // 0' <<< "$L")"
  LW="$(jq '([.stages[] | select(.stage == "extract") | .cost_usd] | add // 0) / ([.pages, 1] | max)' <<< "$L")"
  printf '  triage $%.4f (golden $%.4f) · writer $%.4f/page (golden $%.4f/page)\n' "$LT" "$GT" "$LW" "$GW"
  jq -e -n --argjson l "$LT" --argjson g "$GT" '$l <= 2 * $g' >/dev/null || fail "triage cost regression: \$$LT > 2x golden \$$GT"
  jq -e -n --argjson l "$LW" --argjson g "$GW" '$l <= 2 * $g' >/dev/null || fail "writer cost-per-page regression: \$$LW > 2x golden \$$GW"
  jq -e '.validator_drops == 0 and .postscan_drops == 0' <<< "$L" >/dev/null || echo "  WARN: live run had drops: $(jq -c '{validator_drops, postscan_drops}' <<< "$L")"
  if [[ "$MODE" == "--record" ]]; then
    for st in triage extract; do
      jq '{type, subtype, is_error, duration_ms, num_turns, result, structured_output, total_cost_usd, usage}
          | with_entries(select(.value != null))' "$RUN/$st.json" > "$FIX/recorded/$st.json"
    done
    cp "$RUN/bundle/transcripts/claude-code-1.txt" "$FIX/recorded/bundle-1.txt"
    cp "$RUN/bundle/transcripts/claude-code-2.txt" "$FIX/recorded/bundle-2.txt"
    echo "$PV_NOW" > "$FIX/recorded/PROMPT_VERSION"
    echo "  recorded new golden under prompt_version $PV_NOW (review the diff in test/eval/fixtures before committing)"
  fi
  echo "PASS — live eval"
fi
