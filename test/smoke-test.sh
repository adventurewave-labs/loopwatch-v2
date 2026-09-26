#!/usr/bin/env bash
# loopwatch end-to-end smoke test — stubbed claude CLI, fixture transcripts, throwaway $HOME.
# No network, no real transcripts, no real model. Each case gets a fresh sandbox.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FIXTURES="$SCRIPT_DIR/fixtures"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/loopwatch-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT
fail() { echo "FAIL [$CASE]: $*" >&2; [[ -n "${LWLOG:-}" ]] && tail -30 "$LWLOG" >&2; exit 1; }
ok()   { echo "  ok: $*"; }
CASE=""
N_CASES=0

# ── sandbox ─────────────────────────────────────────────────────────────
# setup: fresh HOME, catalog repo, config. Exposes $W $H $LW_STATE $SITE $REPO $CALLS $TX
setup() {
  CASE="$1"; N_CASES=$((N_CASES + 1))
  echo "— $CASE —"
  W="$TMP_ROOT/$N_CASES"; H="$W/home"
  mkdir -p "$H/.config/loopwatch" "$H/.claude/projects"
  export HOME="$H"
  unset XDG_CONFIG_HOME XDG_STATE_HOME LOOPWATCH_CONF 2>/dev/null || true
  LW_STATE="$H/.local/state/loopwatch"
  CALLS="$W/claude-calls.log"; : > "$CALLS"
  export STUB_CALLS="$CALLS"
  unset STUB_PAGES STUB_TRIAGE STUB_FAIL STUB_HELP_FLAGS STUB_MARKER STUB_DIGEST STUB_HIGHLIGHT 2>/dev/null || true
  LWLOG=""

  REPO="$W/catalog"
  mkdir -p "$REPO"
  git -C "$REPO" init -q -b main 2>/dev/null || git -C "$REPO" init -q
  git -C "$REPO" config user.email "test@test"
  git -C "$REPO" config user.name  "loopwatch-test"
  cp -R "$SRC_ROOT/site" "$REPO/site"
  git -C "$REPO" add -A && git -C "$REPO" commit -qm "init"
  SITE="$REPO/site"

  # a Claude Code project dir holding the real-schema fixture
  TX="$H/.claude/projects/-Users-dev-src-turbo-flow/f1x7ure0.jsonl"
  mkdir -p "$(dirname "$TX")"
  cp "$FIXTURES/claude-code-2.1.jsonl" "$TX"

  cat > "$H/.config/loopwatch/loopwatch.conf" <<EOF
CLAUDE_CODE_GLOBS=("\$HOME/.claude/projects/*/*.jsonl")
COWORK_GLOBS=()
GIT_REPOS=()
CLAUDE_BIN="$SRC_ROOT/test/stubs/claude"
SITE_DIR="$SITE"
ACTIVITY_MIN_BYTES=200
PULL=false
PUSH=false
INCLUDE_PROJECTS=("*")
SITE_VISIBILITY=protected
EOF
  : > "$H/.config/loopwatch/redact.list"
  chmod 600 "$H/.config/loopwatch/redact.list"
}
conf() { echo "$*" >> "$H/.config/loopwatch/loopwatch.conf"; }
lw() { LWLOG="$W/last-run.log"; "$SRC_ROOT/bin/loopwatch-run.sh" "$@" 2> "$LWLOG"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
commits() { git -C "$REPO" rev-list --count HEAD; }
ledger_last() { tail -n 1 "$LW_STATE/runs.jsonl"; }
YEAR="$(date +%Y)"
TODAY="$(date +%F)"

# ═════════════════════════════════════════════════════════════════════════
setup "full pipeline, filter, scrub, ledger"
lw
test -f "$SITE/pages/$YEAR/k8s-cronjob-queue-ingest.html" || fail "page not installed"
jq -e '.entries | length == 1' "$SITE/manifest.json" >/dev/null || fail "manifest entry missing"
jq -e '.digests | length == 1' "$SITE/manifest.json" >/dev/null || fail "digest record missing"
test -f "$SITE/digests/$TODAY.html" || fail "digest page missing"
[[ "$(commits)" == "2" ]] || fail "expected 2 commits (init + loopwatch)"
ok "page, manifest, digest, commit"
B="$LW_STATE/run/bundle/transcripts"
grep -q "CronJob plus work queue" "$B"/*.txt || fail "user text missing from bundle"
grep -q "idempotent" "$B"/*.txt || fail "assistant text missing from bundle"
for bad in "harness-injected" "inline reminder" "private reasoning" "tool output noise" "subagent chatter" "kubectl get"; do
  if grep -q "$bad" "$B"/*.txt; then fail "filter leaked: $bad"; fi
done
grep -q "=== source: claude-code:turbo-flow" "$B"/*.txt || fail "source header should name the project from cwd"
ok "2.1 schema filter: isMeta/isSidechain/thinking/tool noise/system-reminders dropped"
if grep -rq "ghp_abcdefghijklmnopqrstuvwxyz123456" "$SITE" "$LW_STATE"; then fail "planted secret leaked"; fi
ok "planted secret scrubbed"
jq -e '.repo == "loopwatch" and .target == "manual" and .status == "published" and .pages == 1
       and .cost_usd > 0 and .in > 0 and .cached > 0 and .out > 0 and (.ts | test("^[0-9]{4}-"))' \
   <(ledger_last) >/dev/null || fail "ledger line malformed: $(ledger_last)"
grep -q -- "persist=false" "$CALLS" || fail "--no-session-persistence not passed"
grep -q -- "budget=1.00" "$CALLS" || fail "--max-budget-usd not passed"
ok "ledger line valid (cost/tokens parsed from --output-format json); spend cap + no-persist flags passed"

# ═════════════════════════════════════════════════════════════════════════
setup "state holds hashed keys, not paths (bug 7)"
lw
if grep -q "turbo-flow\|/Users/\|$H" "$LW_STATE/watermarks.json"; then fail "watermarks contain a path: $(cat "$LW_STATE/watermarks.json")"; fi
jq -e '.files | keys | all(test("^[0-9a-f]{16}$"))' "$LW_STATE/watermarks.json" >/dev/null || fail "watermark keys not hashed"
if git -C "$REPO" ls-files | grep -q watermarks; then fail "watermarks committed to the catalog repo"; fi
ok "watermark keys are 16-hex hashes; nothing committed"

# ═════════════════════════════════════════════════════════════════════════
setup "empty run: zero model calls (R-2)"
lw
n1="$(calls)"
lw
[[ "$(calls)" == "$n1" ]] || fail "second run with no new activity invoked claude"
jq -e '.status == "skipped" and .skipped_reason == "below_activity_min" and .cost_usd == 0' <(ledger_last) >/dev/null \
  || fail "skip not recorded in ledger: $(ledger_last)"
ok "no-activity run made 0 claude calls and logged skipped_reason"

# ═════════════════════════════════════════════════════════════════════════
setup "self-ingestion excluded (R-4, bug 1)"
export STUB_HELP_FLAGS="--output-format --max-budget-usd"   # CLI without --no-session-persistence
export STUB_MARKER="SELF-INGEST-MARKER-7731"
lw
ls "$H/.claude/projects/" | grep -q "loopwatch-run$" || fail "stub should have persisted a session under the run dir"
n1="$(calls)"
lw --dry-run
if grep -rq "SELF-INGEST-MARKER-7731" "$LW_STATE/run/bundle"; then fail "second bundle contains the first run's session"; fi
[[ "$(calls)" == "$n1" ]] || fail "self-generated transcript alone triggered a model call"
lw --list-sources > "$W/sources.txt"
grep "loopwatch-run" "$W/sources.txt" | grep -q "skip:self" || fail "--list-sources should show the run dir as skip:self"
ok "persisted run transcript excluded; 0 extra calls; list-sources shows skip:self"
unset STUB_HELP_FLAGS STUB_MARKER

# ═════════════════════════════════════════════════════════════════════════
setup "cwd guard: lines from the run dir are dropped even under another project dir"
printf '%s\n' "$(jq -nc --arg cwd "$LW_STATE/run" '{type:"user",cwd:$cwd,message:{role:"user",content:"RUNDIR-CWD-MARKER leaked bundle text"}}')" >> "$TX"
lw --dry-run
if grep -rq "RUNDIR-CWD-MARKER" "$LW_STATE/run/bundle"; then fail "cwd guard failed"; fi
ok "line with cwd == run dir dropped"

# ═════════════════════════════════════════════════════════════════════════
setup "bundle cap trims oldest-first (R-1, bug 2)"
conf "MAX_BUNDLE_KB=8"
conf "MAX_FILE_KB=64"
conf "FIRST_RUN_LOOKBACK_HOURS=999999"
OLD="$H/.claude/projects/-Users-dev-src-old/aaaa.jsonl"
NEW="$H/.claude/projects/-Users-dev-src-new/bbbb.jsonl"
mkdir -p "$(dirname "$OLD")" "$(dirname "$NEW")"
big() { local tag="$1" i; for i in $(seq 1 60); do jq -nc --arg t "$tag line $i $(printf 'y%.0s' $(seq 1 150))" '{type:"user",cwd:"/x/p",message:{role:"user",content:$t}}'; done; }
big OLDEST > "$OLD"; big NEWEST > "$NEW"
touch -t 202001010000 "$OLD"
lw --dry-run
total="$(find "$LW_STATE/run/bundle/transcripts" -type f -exec cat {} + | wc -c | tr -d ' ')"
[[ "$total" -le $((8 * 1024)) ]] || fail "bundle $total B exceeds the 8KB cap"
grep -rq "NEWEST line 60" "$LW_STATE/run/bundle/transcripts" || fail "newest content should survive trimming"
if grep -rq "OLDEST line 1 " "$LW_STATE/run/bundle/transcripts"; then fail "oldest content should be trimmed first"; fi
grep -q "trimmed" "$LWLOG" || fail "trim not logged"
jq -e '.trimmed_bytes > 0 and .bundle_bytes <= 8192' <(ledger_last) >/dev/null || fail "trim not in ledger: $(ledger_last)"
ok "bundle ${total}B ≤ cap, oldest trimmed, logged and in ledger"

# ═════════════════════════════════════════════════════════════════════════
setup "partial trailing line is not lost (bug 3)"
lw
printf '%s' '{"type":"user","cwd":"/Users/dev/src/turbo-flow","message":{"role":"user","content":"PARTIAL-LINE-MARKER decided to shard the queue by tenant so one noisy tenant cannot starve the rest; revisit when the backlog metric' >> "$TX"
lw --dry-run
if grep -rq "PARTIAL-LINE-MARKER" "$LW_STATE/run/bundle"; then fail "partial line should not be read yet"; fi
lw   # real run (no activity) advances watermarks
printf '%s\n' ' is live."}}' >> "$TX"
lw --dry-run
grep -rq "PARTIAL-LINE-MARKER" "$LW_STATE/run/bundle" || fail "completed line was lost"
ok "watermark stops at last newline; completed line collected next run"

# ═════════════════════════════════════════════════════════════════════════
setup "truncated/rotated source is re-read (bug 4)"
lw
jq -nc '{type:"user",cwd:"/Users/dev/src/turbo-flow",message:{role:"user",content:"ROTATED-MARKER fresh session content after rotation with enough text to clear the activity bar for this test case, easily more than two hundred bytes of real content here."}}' > "$TX"
lw --dry-run
grep -rq "ROTATED-MARKER" "$LW_STATE/run/bundle" || fail "content after truncation was ignored"
grep -q "shrank" "$LWLOG" || fail "truncation not logged"
ok "size < watermark resets to 0 and collects the new content"

# ═════════════════════════════════════════════════════════════════════════
setup "first-run lookback skips old history"
touch -t 202001010000 "$TX"
lw
[[ "$(calls)" == "0" ]] || fail "old file on first sighting should not be mined"
jq -e '.files | length == 1' "$LW_STATE/watermarks.json" >/dev/null || fail "old file should be watermarked at its size"
ok "stale file watermarked, not mined"

# ═════════════════════════════════════════════════════════════════════════
setup "dry-run is side-effect free; slug dedup"
lw
printf '%s\n' "$(jq -nc '{type:"user",cwd:"/Users/dev/src/turbo-flow",message:{role:"user",content:"Follow-up on ingest: add a PodDisruptionBudget and set activeDeadlineSeconds so a wedged worker cannot hold the queue. Expose queue depth as a Prometheus gauge for HPA scaling on backlog instead of CPU."}}')" >> "$TX"
lw --dry-run
[[ "$(commits)" == "2" ]] || fail "dry-run must not commit"
jq -e '.entries | length == 1' "$SITE/manifest.json" >/dev/null || fail "dry-run must not touch manifest"
jq -e '.dry_run == true and .status == "dry_run"' <(ledger_last) >/dev/null || fail "dry-run ledger line"
ok "dry-run: no commit, no manifest change, ledger marks dry_run"
lw
jq -e '.entries | length == 1' "$SITE/manifest.json" >/dev/null || fail "duplicate slug was not deduped"
jq -e '.digests | length == 2' "$SITE/manifest.json" >/dev/null || fail "second digest missing"
ok "duplicate slug deduped, digest still recorded"

# ═════════════════════════════════════════════════════════════════════════
setup "budget cap hit: fail closed, watermarks held, ledger records it"
export STUB_FAIL=budget
if lw; then fail "run should fail when the budget cap is hit"; fi
jq -e '.status == "failed" and .skipped_reason == "budget_exceeded" and .cost_usd > 0' <(ledger_last) >/dev/null \
  || fail "budget failure not in ledger: $(ledger_last)"
jq -e '.files | length == 0' "$LW_STATE/watermarks.json" >/dev/null || fail "watermarks advanced after a failed run"
ls "$LW_STATE/failed/" | grep -q . || fail "no autopsy"
ok "budget_exceeded logged with cost, watermarks unchanged, autopsy kept"
unset STUB_FAIL

# ═════════════════════════════════════════════════════════════════════════
setup "allowlist: empty INCLUDE_PROJECTS collects nothing (R-7)"
conf 'INCLUDE_PROJECTS=()'
lw
[[ "$(calls)" == "0" ]] || fail "empty allowlist must not reach the model"
lw --list-sources > "$W/src.txt"
grep -q "skip:not-allowlisted" "$W/src.txt" || fail "--list-sources should show not-allowlisted"
ok "empty allowlist: 0 calls, list-sources explains why"
conf 'INCLUDE_PROJECTS=("*-src-other")'
lw --list-sources > "$W/src.txt"
grep -q "skip:not-allowlisted.*turbo-flow" "$W/src.txt" || fail "non-matching pattern should not include turbo-flow"
conf 'INCLUDE_PROJECTS=("claude-code:*-src-turbo-*")'
lw --list-sources > "$W/src.txt"
grep -q "include.*turbo-flow" "$W/src.txt" || fail "label-prefixed pattern should include turbo-flow: $(cat "$W/src.txt")"
conf 'EXCLUDE_PROJECTS=("*turbo-flow")'
lw --list-sources > "$W/src.txt"
grep -q "skip:not-allowlisted.*turbo-flow" "$W/src.txt" || fail "EXCLUDE_PROJECTS must win"
ok "dir patterns, label:dir patterns, exclude wins"

# ═════════════════════════════════════════════════════════════════════════
setup "privacy: client name, Stripe key, connection string, inline script (R-6, R-11)"
printf '%s\n' 'Globex( Corporation)?' 'Initech=>ACME-2' > "$H/.config/loopwatch/redact.list"
printf '%s\n' "$(jq -nc '{type:"user",cwd:"/Users/dev/src/turbo-flow",message:{role:"user",content:"Shipped the rollout for Globex Corporation and initech today. Stripe key sk_live_ABCDEFGHIJKLMNOPQRSTUVWX, db postgres://admin:hunter2pass@db.internal:5432/app, google AIzaSyA1234567890abcdefghijklmnopqrstuv, VERCEL_TOKEN=abc123def456ghi789"}}')" >> "$TX"
export STUB_PAGES=unsafe
lw
for leak in "Globex" "initech" "sk_live_ABCDEFGH" "hunter2pass" "AIzaSyA1234567890" "abc123def456ghi789"; do
  if grep -rqi -- "$leak" "$LW_STATE/run/bundle" "$SITE" "$LW_STATE/runs.jsonl"; then fail "leaked into bundle/site/ledger: $leak"; fi
done
grep -rq "ACME-2" "$LW_STATE/run/bundle" || fail "custom replacement not applied"
ok "client names + 4 secret kinds redacted before the model; nothing in site/ or ledger"
test -f "$SITE/pages/$YEAR/safe-page-one.html" || fail "safe page should publish"
for bad in inline-script-page onload-handler-page external-img-page iframe-page leaked-stripe-page; do
  if [[ -f "$SITE/pages/$YEAR/$bad.html" ]]; then fail "unsafe page published: $bad"; fi
  if jq -e --arg s "$bad" '.entries | any(.slug == $s)' "$SITE/manifest.json" >/dev/null; then fail "unsafe page in manifest: $bad"; fi
done
if grep -rqiE "<script|onerror=" "$SITE/pages" "$SITE/digests"; then fail "script content reached site/"; fi
jq -e '.validator_drops == 4 and .postscan_drops == 1 and .pages == 1' <(ledger_last) >/dev/null || fail "drop counts wrong: $(ledger_last)"
ok "validator dropped script/on*/external-src/iframe pages; postscan dropped the Stripe page; counts in ledger"

# ═════════════════════════════════════════════════════════════════════════
setup "privacy: model re-introduces a client name -> page dropped, digest withheld"
printf '%s\n' 'Globex( Corporation)?' > "$H/.config/loopwatch/redact.list"
export STUB_PAGES=client
export STUB_DIGEST="Big day for Globex: rollout finished."
export STUB_HIGHLIGHT="globex cutover done"
lw
if grep -rqi "globex" "$SITE" "$LW_STATE/runs.jsonl"; then fail "client name reached site/ or ledger"; fi
test -f "$SITE/pages/$YEAR/clean-page.html" || fail "clean page should survive"
jq -e '.digests[0].summary | test("withheld")' "$SITE/manifest.json" >/dev/null || fail "digest summary should be withheld"
jq -e '.postscan_drops == 3' <(ledger_last) >/dev/null || fail "postscan drops (page+summary+highlight) wrong: $(ledger_last)"
ok "post-extraction scan fails closed on page, digest summary and highlight"

# ═════════════════════════════════════════════════════════════════════════
setup "preflight fails closed (R-5)"
conf 'SITE_VISIBILITY=public'
if lw; then fail "publishing run must fail when the site is not protected"; fi
[[ "$(calls)" == "0" ]] || fail "failed preflight must not reach the model"
jq -e '.status == "failed" and .skipped_reason == "preflight_failed"' <(ledger_last) >/dev/null || fail "preflight failure not in ledger"
if "$SRC_ROOT/bin/loopwatch-run.sh" --preflight > "$W/pf.txt" 2>&1; then fail "--preflight should exit non-zero"; fi
grep -q "^FAIL.*SITE_VISIBILITY" "$W/pf.txt" || fail "--preflight should name the failing check"
ok "unprotected site: run refused before collection, --preflight exits non-zero"
conf 'ALLOW_PUBLIC=true'
"$SRC_ROOT/bin/loopwatch-run.sh" --preflight > "$W/pf.txt" 2>&1 || fail "ALLOW_PUBLIC=true should pass preflight"
grep -q "^WARN.*ALLOW_PUBLIC" "$W/pf.txt" || fail "ALLOW_PUBLIC should warn"
conf 'ALLOW_PUBLIC=false'; conf 'SITE_VISIBILITY=protected'
printf '%s\n' 'bad(regex' > "$H/.config/loopwatch/redact.list"
if "$SRC_ROOT/bin/loopwatch-run.sh" --preflight > "$W/pf.txt" 2>&1; then fail "invalid redact.list regex should fail preflight"; fi
grep -q "^FAIL.*redact.list" "$W/pf.txt" || fail "bad regex not reported"
rm -f "$H/.config/loopwatch/redact.list"
if "$SRC_ROOT/bin/loopwatch-run.sh" --preflight > "$W/pf.txt" 2>&1; then fail "missing redact.list should fail preflight"; fi
ok "ALLOW_PUBLIC override warns; bad or missing redact.list fails"

echo
echo "PASS — $N_CASES cases green"
