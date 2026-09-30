#!/usr/bin/env bash
# Validator fuzzing. Every case is an active payload (vectors.txt) or a mutation of one
# (mutate.py). Both defensive layers are measured INDEPENDENTLY on every case:
#   layer 1  markup allowlist (BODY_GATE_JQ, applied by render_pages to the model's body)
#   layer 2  blocklist validator (html_problem, run on the rendered page file)
# Pages are rendered through the real renderer (render_page_files), with layer 1 bypassed so
# layer 2 is tested on its own.
#
#   test/fuzz/run-fuzz.sh                    CI mode: every case the validator lets through
#                                            must be on inert-allowlist.txt, i.e. previously
#                                            proven inert in a browser. Fast, no browser needed.
#   test/fuzz/run-fuzz.sh --oracle           also load every passing page in headless Chromium
#                                            (oracle.cjs): script ran, network request, or
#                                            navigation = a validator BYPASS -> fail. Also
#                                            reports how many base vectors are really active.
#   test/fuzz/run-fuzz.sh --update-allowlist --oracle-proven inert passers become the allowlist.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HERE/../.." && pwd)"
MODE="${1:-ci}"
W="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-fuzz.XXXXXX")"; trap 'rm -rf "$W"' EXIT
fail() { echo "FAIL [fuzz]: $*" >&2; exit 1; }

python3 "$HERE/mutate.py" > "$W/cases.jsonl" 2> "$W/gen.txt"
jq -s '{structured_output: {pages: map({candidate_id: "c1", slug: ("fz-" + .id), title: "fuzz",
        category: "ideas", tags: [], summary: "fuzz", source: "fuzz", body_html: .body})}}' \
   "$W/cases.jsonl" > "$W/extract.json"
echo '{"run_date":"2026-01-01","digest_summary":"x","highlights":[]}' > "$W/triage-meta.json"

# layer 1: the allowlist control exactly as render_pages applies it: neutralize (escape every
# "<" that does not open a bare allowed tag), then the gate must accept every result.
mkdir -p "$W/l1"
bash -c "source '$SRC_ROOT/lib/extract.sh'; jq -c \"\$BODY_GATE_JQ\"' {id, body: (.body | neutralize)} | . + {ok: (.body | body_ok)}' '$W/cases.jsonl'" > "$W/l1.jsonl"
n_gate_fail="$(jq -s 'map(select(.ok | not)) | length' "$W/l1.jsonl")"
[[ "$n_gate_fail" == 0 ]] || fail "layer 1: $n_gate_fail neutralized bodies still hold non-allowlisted markup"
# ...judged independently too: the gate shares allowed_tail with neutralize, so a loosened
# allowlist would pass its own gate. This regex is the test's own copy of the contract.
n_indep="$(jq -s '[.[] | .body | [scan("<[A-Za-z/!?][^<>]*>?")][]
  | select(test("^</?(h2|h3|h4|p|ul|ol|li|pre|code|strong|em|b|i|table|thead|tbody|tr|th|td|blockquote)>$|^<(br|hr) ?/?>$") | not)] | length' "$W/l1.jsonl")"
[[ "$n_indep" == 0 ]] || fail "layer 1: $n_indep tag(s) outside the bare-tag contract survived neutralize"
# the gate is the backstop behind neutralize, so it must reject the RAW markup neutralize rewrote
n_gate_open="$(bash -c "source '$SRC_ROOT/lib/extract.sh'; jq -c \"\$BODY_GATE_JQ\"' select((.body | neutralize) != .body and (.body | body_ok)) | .id' '$W/cases.jsonl'" | wc -l | tr -d ' ')"
[[ "$n_gate_open" == 0 ]] || fail "layer 1: the gate accepted $n_gate_open raw bodies that neutralize had to rewrite"
jq -s '[.[] | {candidate_id: "c1", slug: ("fz-" + .id), title: "fuzz", category: "ideas", tags: [], summary: "fuzz", source: "fuzz", body_html: .body}]' "$W/l1.jsonl" > "$W/l1/pages.json"
RUN_DIR="$W/l1" RUN_DATE=2026-01-01 bash -c "source '$SRC_ROOT/lib/extract.sh'; render_page_files '$W/l1/pages.json'"
# layer 2: render every case (gate bypassed) through the real renderer, judge with html_problem
jq '.structured_output.pages' "$W/extract.json" > "$W/all-pages.json"
RUN_DIR="$W" RUN_DATE=2026-01-01 bash -c "
  log() { :; }
  source '$SRC_ROOT/lib/extract.sh'; render_page_files '$W/all-pages.json'"
n_rendered="$(find "$W/pages" -name '*.html' | wc -l | tr -d ' ')"
# The page path is passed as an argument, not via -I{}: BSD xargs caps an -I command at
# 255 bytes ("command line cannot be assembled, too long"), which broke this on macOS.
# shellcheck disable=SC2016  # the script is single-quoted on purpose: it expands in the child
find "$W/pages" -name '*.html' | sort | xargs -P 8 -n 1 bash -c '
  p="$(source "$1/lib/publish.sh"; html_problem "$2")" || p=validator-error
  id="${2##*/fz-}"; printf "%s\t%s\n" "${id%.html}" "${p:-PASS}"' _ "$SRC_ROOT" > "$W/verdicts.tsv"
n_cases="$(wc -l < "$W/cases.jsonl" | tr -d ' ')"
[[ "$n_rendered" == "$n_cases" ]] || fail "rendered $n_rendered of $n_cases cases"
grep -q $'\tvalidator-error$' "$W/verdicts.tsv" && fail "validator crashed on: $(grep $'\tvalidator-error$' "$W/verdicts.tsv" | head -3 | cut -f1 | tr '\n' ' ')"
awk -F'\t' '$2 == "PASS" { print $1 }' "$W/verdicts.tsv" | LC_ALL=C sort > "$W/passers.txt"
n_pass="$(wc -l < "$W/passers.txt" | tr -d ' ')"
echo "  $(cat "$W/gen.txt")"
echo "  layer 1 (markup allowlist: neutralize + gate): $n_cases/$n_cases reduced to bare allowed tags only"
echo "  layer 2 (blocklist validator, alone) blocked $(( n_cases - n_pass ))/$n_cases; $n_pass passed through"

if [[ "$MODE" == "ci" ]]; then
  grep -v '^#' "$HERE/inert-allowlist.txt" | LC_ALL=C sort > "$W/allow.txt" || true
  unexpected="$(LC_ALL=C comm -23 "$W/passers.txt" "$W/allow.txt")"
  if [[ -n "$unexpected" ]]; then
    while IFS= read -r id; do jq -r --arg id "$id" 'select(.id == $id) | "    \(.id) [\(.variant)] \(.body)"' "$W/cases.jsonl"; done <<< "$unexpected" | head -20 >&2
    fail "$(wc -l <<< "$unexpected" | tr -d ' ') case(s) passed the validator without a browser-proven inert verdict (run: test/fuzz/run-fuzz.sh --oracle)"
  fi
  echo "PASS — fuzz (every passer is on the browser-proven inert allowlist)"
  exit 0
fi

# --oracle / --update-allowlist: prove passers inert in Chromium
mkdir -p "$W/oracle-pass" "$W/oracle-base"
while IFS= read -r id; do cp "$W/pages/fz-$id.html" "$W/oracle-pass/"; done < "$W/passers.txt"
jq -r 'select(.variant == "base") | .id' "$W/cases.jsonl" | while IFS= read -r id; do cp "$W/pages/fz-$id.html" "$W/oracle-base/"; done
NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}" node "$HERE/oracle.cjs" "$W/oracle-base" > "$W/base.json"
NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}" node "$HERE/oracle.cjs" "$W/oracle-pass" > "$W/pass.json"
echo "  corpus check: $(jq '[.[] | select(. != null)] | length' "$W/base.json")/$(jq 'length' "$W/base.json") base vectors are ACTIVE in Chromium when unfiltered"
bypass="$(jq -r 'to_entries[] | select(.value != null) | "\(.key)\t\(.value)"' "$W/pass.json")"
if [[ -n "$bypass" ]]; then
  while IFS=$'\t' read -r f why; do id="${f#fz-}"; id="${id%.html}"
    jq -r --arg id "$id" --arg why "$why" 'select(.id == $id) | "    BYPASS \(.id) [\(.variant)] \($why): \(.body)"' "$W/cases.jsonl"; done <<< "$bypass" >&2
  fail "$(wc -l <<< "$bypass" | tr -d ' ') validator bypass(es): passed the validator AND were active in Chromium"
fi
echo "  oracle: all $n_pass layer-2 passers are inert in Chromium (no script, no request, no navigation)"
NODE_PATH="${NODE_PATH:-$(npm root -g 2>/dev/null)}" node "$HERE/oracle.cjs" "$W/l1/pages" > "$W/l1.json"
l1_active="$(jq -r 'to_entries[] | select(.value != null) | "\(.key) \(.value)"' "$W/l1.json")"
[[ -z "$l1_active" ]] || fail "layer 1 output ACTIVE in Chromium: $(head -3 <<< "$l1_active")"
echo "  oracle: all $n_cases layer-1 (neutralized) pages are inert in Chromium"
if [[ "$MODE" == "--update-allowlist" ]]; then
  { echo "# ids of fuzz cases that pass the validator and were PROVEN inert in headless Chromium"
    echo "# (regenerate: test/fuzz/run-fuzz.sh --update-allowlist). One 12-hex id per line."
    cat "$W/passers.txt"; } > "$HERE/inert-allowlist.txt"
  echo "  allowlist updated: $n_pass ids"
fi
echo "PASS — fuzz with browser oracle"
