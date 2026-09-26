#!/usr/bin/env bash
# Scrubber coverage against gitleaks-style positive samples and false-positive negatives.
#   test/scrub/run-coverage.sh           fails unless every positive is redacted and every negative is untouched
#   test/scrub/run-coverage.sh --report  prints the per-kind table and exits 0
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$HERE/../.." && pwd)"
W="$(mktemp -d "${TMPDIR:-/tmp}/lw-scrub.XXXXXX")"; trap 'rm -rf "$W"' EXIT
export STATE_DIR="$W/state" RUN_DIR="$W/run" REDACT_LIST=""
mkdir -p "$RUN_DIR"
scrub() { bash -c "log() { :; }; source '$SRC_ROOT/lib/redact.sh'; scrub_all"; }
miss=0 total=0 fp=0 wrong=0
while IFS='|' read -r kind rule text; do
  [[ -z "$kind" || "$kind" == \#* ]] && continue
  total=$((total + 1))
  line="${text//\{\}/}"
  secret="$(sed -E 's/.*\[\[(.*)\]\].*/\1/' <<< "$line")"
  line="${line//\[\[/}"; line="${line//\]\]/}"
  out="$(printf '%s\n' "$line" | scrub)"
  if [[ "$out" == *"$secret"* || "$out" != *"[REDACTED"* ]]; then
    miss=$((miss + 1)); echo "  MISS  $kind: $out"
  elif [[ "$out" != *"[REDACTED:$rule]"* ]]; then
    wrong=$((wrong + 1)); echo "  WRONG-RULE  $kind: expected [REDACTED:$rule], got $out"
  fi
done < "$HERE/positives.txt"
while IFS= read -r line; do
  [[ -z "$line" || "$line" == \#* ]] && continue
  out="$(printf '%s\n' "$line" | scrub)"
  [[ "$out" == "$line" ]] || { fp=$((fp + 1)); echo "  FALSE-POSITIVE: $line -> $out"; }
done < "$HERE/negatives.txt"
echo "  scrubber coverage: $((total - miss))/$total secret kinds redacted ($((total - miss - wrong)) by the intended provider rule); $fp false positive(s) on $(grep -vc '^#' "$HERE/negatives.txt") clean lines"
[[ "${1:-}" == "--report" ]] && exit 0
[[ "$miss" -eq 0 && "$fp" -eq 0 && "$wrong" -eq 0 ]] || { echo "FAIL — scrub coverage"; exit 1; }
echo "PASS — scrub coverage"
