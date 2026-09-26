#!/usr/bin/env bash
# Mutation testing of loopwatch's safety code (SOTA backlog #25).
#
# Each line of mutants.tsv breaks one safety check on purpose: the markup allowlist and the
# blocklist validator, the scrubber rules, the canary and input/post scans, the budget and
# retry guards, the grounding guard and the watermark collector. For every mutant this script
# copies the repo, applies the one edit, and runs the listed suites fastest-first. The mutant
# is KILLED when a suite fails and SURVIVES when every suite still passes: a survivor is a
# safety check no test would notice losing.
#
# Usage: test/mutation/run-mutation.sh [mutant-id ...]
#   MUT_JOBS=2        mutants run in parallel
#   MUT_MIN_SCORE=0   exit 1 when the kill share (percent) is below this
#   MUT_KEEP=1        keep the mutated copies for inspection
# Needs python3 (applies the edits) and everything the listed suites need.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIST="$SCRIPT_DIR/mutants.tsv"
JOBS="${MUT_JOBS:-2}"

suite_cmd() {
  case "$1" in
    scrub) echo "bash test/scrub/run-coverage.sh" ;;
    eval)  echo "bash test/eval/run-eval.sh" ;;
    fuzz)  echo "bash test/fuzz/run-fuzz.sh" ;;
    prop)  echo "bash test/prop/watermarks.sh 8 40" ;;
    smoke) echo "bash test/smoke-test.sh" ;;
    *) echo "unknown suite: $1" >&2; return 1 ;;
  esac
}

# one mutant: copy, apply, run suites; prints "<id>\t<KILLED|SURVIVED|BROKEN>\t<by>\t<secs>"
run_one() {
  local id="$1" row file suites anchor repl dir s start
  row="$(awk -F'\t' -v id="$id" '$1 == id' "$LIST")"
  [[ -n "$row" ]] || { printf '%s\tBROKEN\tno such mutant\t0\n' "$id"; return 0; }
  IFS=$'\t' read -r _ file suites anchor repl _ <<< "$row"
  dir="$WORK/$id"; mkdir -p "$dir"
  (cd "$ROOT_DIR" && git ls-files -z | xargs -0 tar cf -) | (cd "$dir" && tar xf -)
  if ! python3 - "$dir/$file" "$anchor" "$repl" <<'PY'
import sys
def unesc(t):
    out, i = [], 0
    while i < len(t):
        if t[i] == '\\' and i + 1 < len(t):
            out.append({'n': '\n', 't': '\t', '\\': '\\'}.get(t[i+1], '\\' + t[i+1])); i += 2
        else:
            out.append(t[i]); i += 1
    return ''.join(out)
p, a, b = sys.argv[1], unesc(sys.argv[2]), unesc(sys.argv[3])
s = open(p).read()
if s.count(a) != 1: sys.exit(f'anchor found {s.count(a)} times')
open(p, 'w').write(s.replace(a, b))
PY
  then printf '%s\tBROKEN\tanchor did not match\t0\n' "$id"; return 0; fi
  start="$(date +%s)"
  for s in ${suites//,/ }; do
    if ! (cd "$dir" && eval "$(suite_cmd "$s")") > "$dir/.mut-$s.log" 2>&1; then
      printf '%s\tKILLED\t%s\t%s\n' "$id" "$s" "$(( $(date +%s) - start ))"
      [[ -n "${MUT_KEEP:-}" ]] || rm -rf "$dir"
      return 0
    fi
  done
  printf '%s\tSURVIVED\t-\t%s\n' "$id" "$(( $(date +%s) - start ))"
  [[ -n "${MUT_KEEP:-}" ]] || rm -rf "$dir"
}

if [[ "${1:-}" == "--one" ]]; then run_one "$2"; exit 0; fi

command -v python3 >/dev/null || { echo "FATAL: python3 is needed to apply mutants" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-mut.XXXXXX")"
[[ -n "${MUT_KEEP:-}" ]] || trap 'rm -rf "$WORK"' EXIT
export WORK LIST ROOT_DIR MUT_KEEP
if [[ $# -gt 0 ]]; then ids=("$@"); else
  ids=(); while IFS= read -r l; do ids+=("$l"); done < <(grep -v '^#' "$LIST" | cut -f1)
fi
echo "mutation testing: ${#ids[@]} mutant(s), $JOBS in parallel (log: $WORK/results.tsv)"
printf '%s\n' "${ids[@]}" | xargs -P "$JOBS" -I{} bash "$SCRIPT_DIR/run-mutation.sh" --one {} | tee "$WORK/results.tsv"

total="$(grep -vc $'\tBROKEN\t' "$WORK/results.tsv" || true)"
killed="$(grep -c $'\tKILLED\t' "$WORK/results.tsv" || true)"
broken="$(grep -c $'\tBROKEN\t' "$WORK/results.tsv" || true)"
echo "— survivors (a safety check no test notices losing) —"
while IFS=$'\t' read -r id _; do
  printf '  %s: %s\n' "$id" "$(awk -F'\t' -v id="$id" '$1 == id {print $6}' "$LIST")"
done < <(grep $'\tSURVIVED\t' "$WORK/results.tsv" || true)
echo "— kills by suite —"
{ grep $'\tKILLED\t' "$WORK/results.tsv" || true; } | cut -f3 | sort | uniq -c | sed 's/^/  /'
# mutants marked [redundant] break one layer of a check that a second layer fully covers
# (defense in depth): no input can tell them apart, so they are reported but not scored.
redundant="$(grep $'\tSURVIVED\t' "$WORK/results.tsv" | cut -f1 | while IFS= read -r id; do
  awk -F'\t' -v id="$id" '$1 == id && $6 ~ /^\[redundant\]/' "$LIST"; done | grep -c . || true)"
total=$(( total - redundant ))
score=0; [[ "$total" -eq 0 ]] || score=$(( killed * 100 / total ))
echo "mutation score: $killed/$total killed ($score%), $redundant redundant-by-design survivor(s) not scored$([[ "$broken" -eq 0 ]] || echo ", $broken BROKEN")"
[[ "$broken" -eq 0 ]] || exit 1
[[ "$score" -ge "${MUT_MIN_SCORE:-0}" ]] || { echo "below MUT_MIN_SCORE=${MUT_MIN_SCORE}" >&2; exit 1; }
