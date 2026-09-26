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
  unset STUB_TRIAGE_COST STUB_PAGES STUB_TRIAGE STUB_FAIL STUB_HELP_FLAGS STUB_MARKER STUB_DIGEST STUB_HIGHLIGHT 2>/dev/null || true
  LWLOG=""

  # the catalog "GitHub repo": a bare remote seeded with site/ on main
  BARE="$W/catalog-remote.git"
  SEED="$W/seed"
  git init -q --bare "$BARE"
  git -C "$BARE" symbolic-ref HEAD refs/heads/main
  mkdir -p "$SEED"
  git -C "$SEED" init -q
  git -C "$SEED" config user.email "test@test"
  git -C "$SEED" config user.name  "loopwatch-test"
  cp -R "$SRC_ROOT/site" "$SEED/site"
  git -C "$SEED" add -A && git -C "$SEED" commit -qm "init"
  git -C "$SEED" push -q "$BARE" HEAD:refs/heads/main
  CATALOG="$H/.local/state/loopwatch/catalog"
  SITE="$CATALOG/site"
  export STUB_GH_REMOTE="$BARE" STUB_GH_STATE="$W/gh-state" STUB_GH_CALLS="$W/gh-calls.log"
  mkdir -p "$STUB_GH_STATE"; : > "$STUB_GH_CALLS"
  unset STUB_GH_COMMITS STUB_GH_PRS STUB_GH_FAIL 2>/dev/null || true

  # a Claude Code project dir holding the real-schema fixture
  TX="$H/.claude/projects/-Users-dev-src-turbo-flow/f1x7ure0.jsonl"
  mkdir -p "$(dirname "$TX")"
  cp "$FIXTURES/claude-code-2.1.jsonl" "$TX"

  cat > "$H/.config/loopwatch/loopwatch.conf" <<EOF
CLAUDE_CODE_GLOBS=("\$HOME/.claude/projects/*/*.jsonl")
COWORK_GLOBS=()
CLAUDE_BIN="$SRC_ROOT/test/stubs/claude"
GH_BIN="$SRC_ROOT/test/stubs/gh"
CATALOG_REPO="stub/catalog"
GITHUB_SCOPES=()
ACTIVITY_MIN_BYTES=200
INCLUDE_PROJECTS=("*")
SITE_VISIBILITY=protected
EOF
  : > "$H/.config/loopwatch/redact.list"
  chmod 600 "$H/.config/loopwatch/redact.list"
}
conf() { echo "$*" >> "$H/.config/loopwatch/loopwatch.conf"; }
lw() { LWLOG="$W/last-run.log"; "$SRC_ROOT/bin/loopwatch-run.sh" "$@" 2> "$LWLOG"; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
commits() { git -C "$CATALOG" rev-list --count HEAD; }
remote_main_commits() { git -C "$BARE" rev-list --count main; }
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
[[ "$(git -C "$CATALOG" rev-parse --abbrev-ref HEAD)" == "loopwatch/$TODAY" ]] || fail "run should commit on loopwatch/<date>"
[[ "$(remote_main_commits)" == "1" ]] || fail "main on the remote must never be pushed to"
git -C "$BARE" rev-parse -q --verify "refs/heads/loopwatch/$TODAY" >/dev/null || fail "run branch not pushed"
[[ "$(grep -c '^pr create' "$STUB_GH_CALLS")" == "1" ]] || fail "expected exactly one pr create: $(cat "$STUB_GH_CALLS")"
grep -q "^pr create head=loopwatch/$TODAY base=main" "$STUB_GH_CALLS" || fail "PR head/base wrong"
grep -q "Settled the Turbo-Flow" "$STUB_GH_STATE/pr-1-body.md" || fail "PR body should carry the digest"
ok "page, manifest, digest committed on loopwatch/<date>, pushed, exactly one PR, main untouched"
B="$LW_STATE/run/bundle/transcripts"
grep -q "CronJob plus work queue" "$B"/*.txt || fail "user text missing from bundle"
grep -q "idempotent" "$B"/*.txt || fail "assistant text missing from bundle"
for bad in "harness-injected" "inline reminder" "private reasoning" "tool output noise" "subagent chatter"; do
  if grep -q "$bad" "$B"/*.txt; then fail "filter leaked: $bad"; fi
done
grep -q "^\[tool:Bash\] kubectl get cronjobs" "$B"/*.txt || fail "tool call should be kept as a compact [tool:Name] line"
grep -q "=== source: claude-code:turbo-flow" "$B"/*.txt || fail "source header should name the project from cwd"
ok "2.1 schema filter: isMeta/isSidechain/thinking/tool results/system-reminders dropped; tool calls compacted"
if grep -rq "ghp_abcdefghijklmnopqrstuvwxyz123456" "$SITE" "$LW_STATE"; then fail "planted secret leaked"; fi
ok "planted secret scrubbed"
jq -e '.repo == "loopwatch" and .target == "manual" and .status == "published" and .pages == 1
       and .cost_usd > 0 and .in > 0 and .cached > 0 and .out > 0 and (.ts | test("^[0-9]{4}-"))' \
   <(ledger_last) >/dev/null || fail "ledger line malformed: $(ledger_last)"
grep -q -- "persist=false" "$CALLS" || fail "--no-session-persistence not passed"
grep -q -- "stage=triage model=haiku .*budget=0.30 tools=Read,Glob,Grep " "$CALLS" || fail "triage call wrong: $(cat "$CALLS")"
grep -q -- "stage=extract model=sonnet .*budget=0.97 " "$CALLS" || fail "stage B should get the remaining budget: $(cat "$CALLS")"
ok "ledger line valid (cost/tokens parsed from --output-format json); spend cap + no-persist flags passed"

# ═════════════════════════════════════════════════════════════════════════
setup "state holds hashed keys, not paths (bug 7)"
lw
if grep -q "turbo-flow\|/Users/\|$H" "$LW_STATE/watermarks.json"; then fail "watermarks contain a path: $(cat "$LW_STATE/watermarks.json")"; fi
jq -e '.files | keys | all(test("^[0-9a-f]{16}$"))' "$LW_STATE/watermarks.json" >/dev/null || fail "watermark keys not hashed"
if git -C "$CATALOG" ls-files | grep -q watermarks; then fail "watermarks committed to the catalog repo"; fi
ok "watermark keys are 16-hex hashes; nothing committed"

# ═════════════════════════════════════════════════════════════════════════
setup "empty run: zero model calls (R-2)"
lw
n1="$(calls)"
lw
[[ "$(calls)" == "$n1" ]] || fail "second run with no new activity invoked claude"
jq -e '.status == "skipped" and .skipped_reason == "below_activity_min" and .cost_usd == 0' <(ledger_last) >/dev/null \
  || fail "skip not recorded in ledger: $(ledger_last)"
[[ "$(wc -l < "$LW_STATE/runs.jsonl" | tr -d ' ')" == "2" ]] || fail "expected exactly 2 ledger rows: $(cat "$LW_STATE/runs.jsonl")"
if grep -q '"status":"failed"' "$LW_STATE/runs.jsonl"; then fail "spurious failed row in the ledger"; fi
ok "no-activity run made 0 claude calls and logged skipped_reason (one row per run, no spurious rows)"

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

# ═════════════════════════════════════════════════════════════════════════
setup "two-tier: empty triage never calls stage B (R-3)"
export STUB_TRIAGE=none
lw
[[ "$(calls)" == "1" ]] || fail "expected exactly 1 (triage) call, got $(calls)"
grep -q "stage=triage model=haiku" "$CALLS" || fail "triage must use the cheap model"
if grep -q "stage=extract" "$CALLS"; then fail "stage B ran on an empty candidate list"; fi
jq -e '.model == "haiku" and .pages == 0 and .stage_b_skipped == "no_candidates" and .status == "published"' <(ledger_last) >/dev/null \
  || fail "ledger should show a haiku-only run: $(ledger_last)"
test -f "$SITE/digests/$TODAY.html" || fail "digest should still publish on a no-page day"
grep -q "Quiet day\|Settled" "$SITE/digests/$TODAY.html" || fail "digest should carry the triage summary"
ok "0 candidates: 1 haiku call, no sonnet, digest still published, ledger model=haiku"

# ═════════════════════════════════════════════════════════════════════════
setup "two-tier: stage B sees only cited excerpts"
lw
grep "stage=extract" "$CALLS" | grep -q "bundle=no excerpts=c1.txt," || fail "stage B must run without the bundle, with excerpts: $(cat "$CALLS")"
test -f "$LW_STATE/run/excerpts/c1.txt" || fail "excerpt not written"
grep -q "CronJob plus work queue" "$LW_STATE/run/excerpts/c1.txt" || fail "excerpt lacks the cited lines"
test -d "$LW_STATE/run/bundle/transcripts" || fail "bundle not restored after stage B"
if grep -q "root:" "$LW_STATE/run/excerpts/c1.txt"; then fail "evidence outside the bundle was read"; fi
jq -e '.model == "haiku+sonnet" and (.stages | length) == 2 and .cost_usd == 0.15' <(ledger_last) >/dev/null || fail "ledger stages wrong: $(ledger_last)"
jq -e '.digests[0].summary | test("Settled")' "$SITE/manifest.json" >/dev/null || fail "digest must come from triage"
ok "excerpts only, ../ evidence ignored, bundle restored, ledger sums both stages"

# ═════════════════════════════════════════════════════════════════════════
setup "two-tier: traversal-only evidence drops the candidate; garbage triage fails closed"
export STUB_TRIAGE=traversal
lw
if grep -q "stage=extract" "$CALLS"; then fail "candidate with only out-of-bundle evidence should be dropped"; fi
ok "out-of-bundle evidence ignored; candidate dropped before stage B"
setup "garbage triage"
export STUB_TRIAGE=garbage
if lw; then fail "unparseable triage should fail the run"; fi
jq -e '.skipped_reason == "triage_parse_error"' <(ledger_last) >/dev/null || fail "parse error not in ledger"
jq -e '.files | length == 0' "$LW_STATE/watermarks.json" >/dev/null || fail "watermarks advanced after a failed triage"
ok "unparseable triage: failed, watermarks held"

# ═════════════════════════════════════════════════════════════════════════
setup "two-tier: triage eats the budget -> stage B skipped"
conf 'BUDGET_USD=0.30'
export STUB_TRIAGE_COST=0.28
lw
if grep -q "stage=extract" "$CALLS"; then fail "stage B should not run with < \$0.05 left"; fi
jq -e '.stage_b_skipped == "budget"' <(ledger_last) >/dev/null || fail "budget skip not in ledger: $(ledger_last)"
ok "stage B skipped when the run budget is spent"

# ═════════════════════════════════════════════════════════════════════════
setup "GitHub source via API, zero local repos (R-8)"
conf 'INCLUDE_PROJECTS=()'
conf 'GITHUB_SCOPES=("user:marcuspat" "org:adventurewave-labs")'
export STUB_GH_COMMITS="$FIXTURES/gh-search-commits.json" STUB_GH_PRS="$FIXTURES/gh-search-prs.json"
lw --dry-run
G="$LW_STATE/run/bundle/git"
grep -q "commit marcuspat/turbo-rig a1b2c3d 2026-09-25  feat(gate): record cost_usd per gate verdict" "$G"/github-user-marcuspat.log || fail "commit line missing: $(cat "$G"/*)"
grep -q "PR merged marcuspat/turbo-rig#42" "$G"/github-user-marcuspat.log || fail "merged PR missing"
if grep -rq "ghp_abcdefghijklmnopqrstuvwxyz999999" "$G"; then fail "secret in commit message not scrubbed"; fi
grep -q "api search/commits q=user:marcuspat author:marcuspat committer-date:>20" "$STUB_GH_CALLS" || fail "commit query wrong: $(cat "$STUB_GH_CALLS")"
grep -q "api search/issues q=org:adventurewave-labs is:pr is:merged merged:>20" "$STUB_GH_CALLS" || fail "PR query wrong"
grep -q "stage=triage" "$CALLS" || fail "GitHub-only activity should reach triage"
ok "commits + merged PRs per scope, author resolved from gh, secrets scrubbed, no local clones"
lw
since1="$(jq -r '.github.since' "$LW_STATE/watermarks.json")"
[[ "$since1" =~ ^20[0-9-]+T[0-9:]+Z$ ]] || fail "github watermark not a UTC timestamp: $since1"
: > "$STUB_GH_CALLS"
lw --dry-run
grep -q "committer-date:>$since1" "$STUB_GH_CALLS" || fail "second run should query since the watermark"
ok "timestamp watermark advances and is used as the next window"

setup "GitHub search failure holds the GitHub watermark"
conf 'GITHUB_SCOPES=("org:adventurewave-labs")'
export STUB_GH_FAIL=search
lw
jq -e '.github.since == null' "$LW_STATE/watermarks.json" >/dev/null || fail "github watermark advanced despite a failed search"
jq -e '.files | length == 1' "$LW_STATE/watermarks.json" >/dev/null || fail "transcript watermark should still advance"
grep -q "GitHub commit search failed" "$LWLOG" || fail "failure not logged"
ok "failed search: transcripts published, GitHub window retried next run"

# ═════════════════════════════════════════════════════════════════════════
setup "publishing: one rolling PR, never main (R-9)"
lw
printf '%s\n' "$(jq -nc '{type:"user",cwd:"/Users/dev/src/turbo-flow",message:{role:"user",content:"Second session: decided the spot pool needs a PodDisruptionBudget with minAvailable 1 so voluntary evictions never drain every ingest worker at once; recorded as the standing policy for batch pools."}}')" >> "$TX"
export STUB_PAGES=two
lw
[[ "$(grep -c '^pr create' "$STUB_GH_CALLS")" == "1" ]] || fail "second run must not open a second PR"
grep -q "^pr comment 1" "$STUB_GH_CALLS" || fail "second run should comment on the open PR"
[[ "$(git -C "$BARE" rev-list --count "loopwatch/$TODAY")" == "3" ]] || fail "second run should add a commit to the PR branch"
[[ "$(remote_main_commits)" == "1" ]] || fail "main was pushed to"
git -C "$BARE" show "loopwatch/$TODAY:site/manifest.json" | jq -e '.entries | length == 2' >/dev/null || fail "PR branch manifest should hold both pages"
ok "second run added to the open PR branch; one PR total; main untouched"

setup "publishing: push failure fails closed"
lw --dry-run
[[ "$(grep -c '^pr create' "$STUB_GH_CALLS")" == "0" ]] || fail "dry-run must not open a PR"
if git -C "$BARE" rev-parse -q --verify "refs/heads/loopwatch/$TODAY" >/dev/null; then fail "dry-run must not push"; fi
ok "dry-run: no push, no PR"
git -C "$CATALOG" remote set-url origin "$W/does-not-exist.git"
if lw; then fail "run should fail when the push fails"; fi
jq -e '.status == "failed"' <(ledger_last) >/dev/null || fail "failure not in ledger"
jq -e '.files | length == 0' "$LW_STATE/watermarks.json" >/dev/null || fail "watermarks advanced without a pushed PR"
ok "unreachable remote: run fails, watermarks held"

# ═════════════════════════════════════════════════════════════════════════
setup "CLI: setup, run, ledger, schedule print (R-13)"
rm -f "$H/.config/loopwatch/loopwatch.conf" "$H/.config/loopwatch/redact.list"
"$SRC_ROOT/bin/loopwatch" setup > "$W/setup.txt"
test -f "$H/.config/loopwatch/loopwatch.conf" || fail "setup should create the conf"
[[ "$(stat -c %a "$H/.config/loopwatch/redact.list" 2>/dev/null || stat -f %Lp "$H/.config/loopwatch/redact.list")" == "600" ]] || fail "redact.list should be 0600"
test -L "$H/.local/bin/loopwatch" || fail "setup should link ~/.local/bin/loopwatch"
grep -q '^INCLUDE_PROJECTS=($' "$H/.config/loopwatch/loopwatch.conf" || fail "fresh conf must ship an empty allowlist"
"$SRC_ROOT/bin/loopwatch" setup > "$W/setup2.txt"; grep -q "keep:" "$W/setup2.txt" || fail "second setup must not overwrite"
ok "setup creates conf (empty allowlist), 0600 redact.list, PATH link; idempotent"
# back to the sandbox config for a real run through the CLI entry point
cat >> "$H/.config/loopwatch/loopwatch.conf" <<EOF
CLAUDE_BIN="$SRC_ROOT/test/stubs/claude"
GH_BIN="$SRC_ROOT/test/stubs/gh"
CATALOG_REPO="stub/catalog"
GITHUB_SCOPES=()
COWORK_GLOBS=()
CLAUDE_CODE_GLOBS=("\$HOME/.claude/projects/*/*.jsonl")
INCLUDE_PROJECTS=("*")
ACTIVITY_MIN_BYTES=200
EOF
LWLOG="$W/cli.log"
"$H/.local/bin/loopwatch" run 2> "$LWLOG" || fail "loopwatch run via the PATH link failed"
test -f "$SITE/pages/$YEAR/k8s-cronjob-queue-ingest.html" || fail "loopwatch run did not publish"
jq -e '.target == "manual"' <(ledger_last) >/dev/null || fail "on-demand run should be target=manual"
LOOPWATCH_TARGET=nightly "$SRC_ROOT/bin/loopwatch" run 2>> "$LWLOG"
jq -e '.target == "nightly" and .status == "skipped"' <(ledger_last) >/dev/null || fail "target override not recorded"
"$SRC_ROOT/bin/loopwatch" ledger > "$W/ledger.txt"
grep -q "all-time: 2 runs, 1 with model calls, 1 pages" "$W/ledger.txt" || fail "ledger summary wrong: $(cat "$W/ledger.txt")"
"$SRC_ROOT/bin/loopwatch" schedule print 6 5 > "$W/plist.xml"
grep -q "<string>nightly</string>" "$W/plist.xml" || fail "scheduled runs must be target=nightly"
grep -q "<integer>6</integer>" "$W/plist.xml" || fail "hour not rendered"
if grep -q "__" "$W/plist.xml"; then fail "unrendered placeholder in plist"; fi
[[ "$("$SRC_ROOT/bin/loopwatch" version)" == "loopwatch "* ]] || fail "version"
ok "loopwatch run (manual) + nightly target in ledger; ledger summary; plist renders; nothing scheduled by default"
if [[ -e "$H/Library/LaunchAgents" ]]; then fail "setup/run must not install a schedule"; fi

# ═════════════════════════════════════════════════════════════════════════
setup "exports: --export-md (R-15) and EXPORT_DIGEST_TO (R-16)"
conf "EXPORT_DIGEST_TO=\"$W/rig-inbox\""
lw --export-md "$W/md"
MD="$W/md/k8s-cronjob-queue-ingest.md"
test -f "$MD" || fail "markdown export missing"
head -1 "$MD" | grep -q '^---$' || fail "front-matter missing"
grep -q '^slug: k8s-cronjob-queue-ingest$' "$MD" || fail "slug front-matter"
grep -q '^category: infra/kubernetes$' "$MD" || fail "category front-matter"
grep -q '^# Turbo-Flow ingest: CronJob + work queue' "$MD" || fail "title heading"
if grep -q '<[a-z]' "$MD"; then fail "HTML left in markdown export"; fi
D="$W/rig-inbox/loopwatch-$TODAY.md"
test -f "$D" || fail "digest export missing"
grep -q "Settled the Turbo-Flow" "$D" || fail "digest export lacks the summary"
grep -q "pull/1" "$D" || fail "digest export should link the PR"
ok "page -> Markdown with front-matter; digest dropped in the Turbo Rig inbox with PR link"

# ═════════════════════════════════════════════════════════════════════════
setup "Cowork source label + cowork:* allowlist (R-14 path, schema pending)"
CW="$H/Library/Application Support/Claude/local-agent-mode-sessions/acct1/sess1"
mkdir -p "$CW"
cp "$FIXTURES/claude-code-2.1.jsonl" "$CW/s1.jsonl"
conf 'COWORK_GLOBS=("$HOME/Library/Application Support/Claude/local-agent-mode-sessions/*/*/*.jsonl")'
conf 'INCLUDE_PROJECTS=("cowork:*")'
lw --dry-run
ls "$LW_STATE/run/bundle/transcripts" | grep -q "^cowork-" || fail "cowork transcript not collected"
if ls "$LW_STATE/run/bundle/transcripts" | grep -q "^claude-code-"; then fail "cowork:* must not include claude-code sources"; fi
grep -q "=== source: cowork:" "$LW_STATE/run/bundle/transcripts"/cowork-*.txt || fail "cowork label missing"
ok "glob with spaces in the path, cowork label, label-scoped allowlist"

echo
echo "PASS — $N_CASES cases green"
