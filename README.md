# loopwatch

Turns the day's Claude Code, Cowork and GitHub activity into a **private, searchable reference catalog**. Each run stays within a fixed token budget and is published through a **PR you merge**. Run it on demand from a session ("run loopwatch"), or opt in to a nightly schedule.

```
~/.claude/projects/*/*.jsonl ┐  allowlist (INCLUDE_PROJECTS) · self-exclusion · byte watermarks
Cowork session *.jsonl       ├─ filter (text + compact [tool:X] lines) · scrub secrets + redact.list
GitHub API (commits, PRs)    ┘  your commits + merged PRs · catalog repo excluded · no local clones
                                        │  MAX_BUNDLE_KB cap, oldest trimmed first
                                        ▼  (below ACTIVITY_MIN_BYTES: stop — zero model calls)
                 Stage A  triage   haiku, read-only  → digest + 0..5 candidates with line-range evidence
                                        │  (0 candidates: stop — no Stage B)
                 Stage B  writing  sonnet, sees ONLY the cited excerpts → pages/*.html
                                        ▼
                 validator (no script/handlers/embeds/external loads) → post-scan (secrets + redact.list)
                                        ▼
                 catalog repo: loopwatch/<date>-<time> branch (or the open PR) → gh pr create → you review and merge → Railway serves main behind auth
                                        ▼
                 ledger row (~/.local/state/loopwatch/runs.jsonl): tokens, cost, pages, skip reason
```

## Install (Mac)

```sh
gh repo clone adventurewave-labs/loopwatch-v2 ~/.local/share/loopwatch
~/.local/share/loopwatch/bin/install.sh      # creates ~/.config/loopwatch/{loopwatch.conf,redact.list}, links ~/.local/bin/loopwatch
$EDITOR ~/.config/loopwatch/loopwatch.conf   # INCLUDE_PROJECTS: empty means nothing is collected
$EDITOR ~/.config/loopwatch/redact.list      # client / entity names, one regex per line
loopwatch sources                            # what would be collected, and why each source is in or out
loopwatch preflight                          # privacy + visibility checks
loopwatch dry-run                            # full pipeline, nothing published, staging kept
loopwatch run                                # the real thing: opens or updates the catalog PR
```

The installer needs `bash` (stock 3.2 is fine), `jq`, `git`, an authenticated `gh`, and the `claude` CLI. It installs no schedule. To add one:
`loopwatch schedule install 21 30` (launchd, `target=nightly`). Remove it with `loopwatch schedule remove`.

From a Claude Code or Cowork session, just ask: *"run loopwatch"*. That runs `loopwatch run`. The ledger row records `target: manual`.

## Commands

| | |
|---|---|
| `loopwatch run [--export-md DIR]` | collect → triage → write → validate → PR |
| `loopwatch dry-run` | same, without publishing. The run dir is kept for inspection |
| `loopwatch sources` | every candidate source with `include` / `skip:self` / `skip:not-allowlisted` |
| `loopwatch preflight` | PASS/WARN/FAIL checks. Exits non-zero on any FAIL |
| `loopwatch ledger [N]` | last N runs, plus totals and the median cost of runs that made model calls |
| `loopwatch discover` | read-only report on this machine's transcript paths and schema (Phase 0) |
| `loopwatch schedule install [HH MM] \| remove \| print` | opt-in nightly launchd job |
| `loopwatch setup` / `update` / `version` | |

## Cost controls

- **Zero calls on quiet days.** A run stops before any model call if the new content (headers excluded) is under `ACTIVITY_MIN_BYTES` (default 2000, provisional). Transcripts from loopwatch's own runs never count toward it.
- **Hard caps.** `MAX_BUNDLE_KB` caps the whole bundle (oldest content is trimmed first, and the trim is logged). `BUDGET_USD` caps each run. It is passed to every call as `--max-budget-usd`: triage gets `min(TRIAGE_BUDGET_USD, BUDGET_USD)`, and the writer gets what's left. A call that hits its cap fails the run **closed**: watermarks are held and the ledger records `skipped_reason: budget_exceeded`.
- **Two tiers, one call each.** Haiku triages everything. Sonnet runs only when triage found candidates, and gets only the cited line ranges. Both calls are tool-free (`--tools ""`), schema-constrained (`--json-schema`, with triage evidence pinned to the run's real file paths), and run with extended thinking off (`THINKING_TOKENS=0`).
- **Visible.** Every run appends one JSON line to `~/.local/state/loopwatch/runs.jsonl`. It uses Turbo Rig's field names (`ts, repo, target, model, in, cached, out, cost_usd, duration_ms`) plus `pages, skipped_reason, status, stages[], bundle_bytes, trimmed_bytes, validator_drops, postscan_drops`. The file is separate from `gate-log.jsonl`, so gate-verdict stats stay clean.

Measured on claude 2.1.283, on the same sample day (dry runs, not a monthly average). Structured mode: a **3-page day cost $0.158** in 69s ($0.057 Haiku + $0.101 Sonnet). The earlier agentic mode, with tool reads and a model-written HTML file, produced **1 page for $0.376**. That is about 83% less per page. Each `claude -p` call has a fixed floor of about $0.013–0.018.

## Privacy is enforced, not advised

- **Allowlist.** Only sources matching `INCLUDE_PROJECTS` are read, and an empty list reads nothing, GitHub included. Patterns match the dir name (`*-src-turbo-flow`) or `label:name` (`cowork:*`, `github:marcuspat/*`). `EXCLUDE_PROJECTS` wins. The catalog repo is always excluded from GitHub collection, so loopwatch never re-reads its own output.
- **Model isolation.** Neither model call gets any tool (`--tools ""`), so the model cannot read or write files. It sees only what loopwatch puts on stdin: the scrubbed bundle for triage, and only the cited excerpts for the writer. All collected data is fenced in `<file>`/`<excerpt>` tags that the system prompt defines as data, never instructions (spotlighting), and a fence tag inside the data is neutralized so content cannot close it. Page HTML is rendered by loopwatch from the returned body, then validated.
- **Scrub before the model.** Built-in patterns cover OpenAI/Anthropic `sk-` keys, Stripe `sk_/rk_/pk_ live/test`, GitHub tokens, AWS, Slack, Google `AIza`, JWTs, PEM headers, bearer tokens, `scheme://user:pass@` connection strings, `password=`/`token:`/`api_key=` assignments, and emails. On top of those, every line of your gitignored `redact.list` is applied, case-insensitive, with an optional `=>replacement`.
- **Scan after the model.** Pages, titles, summaries, tags, slugs and the digest are re-scanned with the same rules. Any hit drops the page, or withholds the digest text. The drop is counted in the ledger without the matched text.
- **Page firewall.** The validator reads real tags (a quoted `>` does not end a tag), decodes character references, and strips tab/CR/LF before matching. It drops any page with `<script`, `on*=` handlers, `iframe/object/embed/form/link/base/svg/math`, `<meta http-equiv>`, an external/`javascript:`/`data:` (non-image) URL in `src`/`href`/`srcset`/`action`/`poster`/…, or any CSS `url()`/`@import`/`expression()`. The catalog's CSP (`script-src 'self'`) is a second layer.
- **Private catalog.** A publishing run refuses to start unless `SITE_VISIBILITY=protected`. With `SITE_URL` set, preflight also fetches `manifest.json` without credentials and fails unless the request is refused. The catalog is served on Railway by the catalog repo's `server.js`: Basic Auth, **fail closed** (503 until `CATALOG_USER`/`CATALOG_PASSWORD` are set), strict CSP (`script-src 'self'`) and `noindex`.
- **No paths in state.** Watermark keys are sha256 hashes, and state lives in `~/.local/state/loopwatch`. Nothing from state is committed anywhere.

## Publishing model

The catalog is a separate private repo (`CATALOG_REPO`, default `marcuspat/loopwatch-catalog`) holding `site/` only. loopwatch keeps a tool-managed clone under `~/.local/state/loopwatch/catalog`.

- **Branches and PRs.** A run with no open loopwatch PR starts a fresh `loopwatch/<date>-<time>` branch from `main` and opens a PR. While a loopwatch PR is open, later runs add commits to it, so there is at most one open PR and `manifest.json` never conflicts. If `gh` can't say whether a PR is open, the run fails rather than risk a second one.
- **Closing a PR discards it.** A closed PR's branch is never reused, so its content is not re-proposed and not re-mined.
- **Push safety.** loopwatch refuses to push anything except `loopwatch/*` branches. Watermarks advance only after the push lands.

## Correctness

- Transcripts are watermarked by byte offset. The watermark stops at the **last newline**, so a session still being written never loses its tail. A file that shrank is re-read from 0. The first sighting of a file only mines it if it was touched in the last `FIRST_RUN_LOOKBACK_HOURS` (48).
- **No self-ingestion.** Headless calls use `--no-session-persistence` and always run from `~/.local/state/loopwatch/run`. That project dir, and v0.1's `loopwatch-XXXXXX` temp dirs, are excluded, and lines whose `cwd` is the run dir are dropped. See `docs/revival-notes.md` for the experiment that confirmed the bug.
- A mkdir lock serializes runs. It records its PID, and a lock whose process is gone (or older than `LOCK_STALE_HOURS`) is reclaimed, so a crash can't silently stop later runs. A run that finds a live lock writes a `skipped_reason: locked` ledger row.
- A result the CLI flags as an error (`is_error: true`) fails the run, even when `claude` exits 0.
- Transcript lines are parsed one at a time, so a malformed line is skipped without losing the rest.
- Any failure leaves an autopsy (the whole run dir) in `~/.local/state/loopwatch/failed/`, keeping the last 5.

## Seams

- **Turbo Rig:** the ledger above. `EXPORT_DIGEST_TO=~/turbo-rig/memory/inbox/` also writes `loopwatch-YYYY-MM-DD.md` next to the rig's own digest.
- **turbo-brain:** `site/manifest.json` v1 is a documented contract (`docs/manifest-schema.md`). `--export-md DIR` writes pages as Markdown with front-matter.

## Layout

```
bin/loopwatch            CLI entry (run, dry-run, sources, preflight, ledger, discover, schedule, setup)
bin/loopwatch-run.sh     the pipeline
bin/loopwatch-discover.sh read-only Phase 0 discovery
bin/install.sh           tool install (no schedule)
lib/collect.sh           transcripts: allowlist, self-exclusion, watermarks, filter, bundle cap
lib/collect_github.sh    GitHub API source
lib/redact.sh            scrub + post-scan rules
lib/extract.sh           two-tier extraction
lib/publish.sh           validator, digest, manifest merge
lib/catalog.sh           catalog clone, branch, push, PR
lib/preflight.sh         privacy/visibility checks
lib/export.sh            --export-md, EXPORT_DIGEST_TO
lib/common.sh            claude runner (flag detection, JSON usage), ledger
prompts/triage.md        Stage A: the value bar and candidate contract
prompts/extract.md       Stage B: page contract
site/                    catalog UI seed (index.html, app.js, manifest.json)
catalog-template/        catalog repo files: server.js (auth, fails closed), railway.json, catalog-check CI
test/smoke-test.sh       37 sandboxed end-to-end cases, stubbed claude + gh
docs/                    PRD-v0.2, revival notes, manifest schema, v0.1 PRD
```

## Test and release

```sh
test/smoke-test.sh   # no network, no real model, no real transcripts, ~30s
```

CI runs the smoke suite on ubuntu, and on macOS under `/bin/bash`. That is stock 3.2.57, the same bash launchd uses, with the BSD userland. It also runs `shellcheck -S error`. CI runs on every push and PR, and weekly. `bin/ship.sh [patch|minor|major]` runs the tests, bumps `VERSION`, tags, and pushes. `release.yml` gates the GitHub release on the same suite.

## Not in v0.2

The SessionEnd real-time trigger (deferred until the ledger shows stable costs), cross-day pattern learning, full-text body search, and any server or database. Cowork's transcript path is still the v0.1 guess until `loopwatch discover` confirms it on the Mac. Claude Code Desktop *cloud* sessions may not write local transcripts at all.
