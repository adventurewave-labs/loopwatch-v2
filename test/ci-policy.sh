#!/usr/bin/env bash
# CI supply-chain policy check (OpenSSF Scorecard-style baseline), dependency-free.
#   test/ci-policy.sh [workflow files...]   (default: every workflow in this repo + the catalog template)
# Rules, per workflow file:
#   R1 every `uses:` is pinned to a full 40-hex commit SHA with a `# vX.Y.Z` comment (or is local ./)
#   R2 a top-level `permissions:` block exists (least privilege by default), never write-all
#   R3 every actions/checkout sets `persist-credentials: false` (no token left in .git/config)
#   R4 no `pull_request_target` trigger and no attacker-controlled expressions
#      (github.event.*, github.head_ref) anywhere: script-injection vectors
#   R5 every job has `timeout-minutes` (count of runs-on == count of timeout-minutes)
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
if [[ $# -gt 0 ]]; then files=("$@"); else files=("$ROOT"/.github/workflows/*.yml "$ROOT"/catalog-template/.github/workflows/*.yml); fi
bad=0
v() { echo "  VIOLATION ${1##*/}: $2"; bad=$((bad + 1)); }
for f in "${files[@]}"; do
  [[ -f "$f" ]] || continue
  while IFS= read -r line; do
    ref="$(sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//' <<< "$line")"
    [[ "$ref" == ./* ]] && continue
    [[ "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}[[:space:]]+#[[:space:]]*v[0-9] ]] || v "$f" "R1 unpinned action: $ref"
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:' "$f")
  grep -qE '^permissions:' "$f" || v "$f" "R2 no top-level permissions block"
  grep -qE 'permissions:[[:space:]]*write-all' "$f" && v "$f" "R2 write-all permissions"
  awk '/uses:[[:space:]]*actions\/checkout@/ { pending = 1; seen = 0; n = 0; next }
       pending { n++; if ($0 ~ /persist-credentials:[[:space:]]*false/) seen = 1
                 if (n >= 3 || $0 ~ /^[[:space:]]*- /) { if (!seen) bad++; pending = 0 } }
       END { if (pending && !seen) bad++; exit bad > 0 }' "$f" || v "$f" "R3 checkout without persist-credentials: false"
  grep -qE '^[[:space:]]*pull_request_target:|pull_request_target' "$f" && v "$f" "R4 pull_request_target trigger"
  grep -qE '\$\{\{[^}]*(github\.event\.|github\.head_ref)' "$f" && v "$f" "R4 attacker-controlled expression"
  jobs="$(grep -cE '^[[:space:]]+runs-on:' "$f")"; to="$(grep -cE '^[[:space:]]+timeout-minutes:' "$f")"
  [[ "$jobs" == "$to" ]] || v "$f" "R5 $jobs job(s) but $to timeout-minutes"
done
if [[ "$bad" -gt 0 ]]; then echo "FAIL — ci-policy: $bad violation(s)"; exit 1; fi
echo "PASS — ci-policy (${#files[@]} workflow file(s): pinned SHAs, least privilege, no persisted creds, no injection vectors, timeouts)"
