# loopwatch

Unattended nightly loop: mines your Claude Code sessions, Cowork sessions, and git activity for anything of durable reference value, publishes self-contained HTML pages + a daily digest into your HTML repo, and lets your existing push→Vercel pipeline do the rest.

> **Privacy is enforced, not advised (v0.2):** transcripts are collected only from allowlisted projects (`INCLUDE_PROJECTS`, empty = nothing). Secrets and every term in your local `redact.list` are scrubbed before the model sees anything, and generated pages are re-scanned afterwards, with any hit dropping the page. A publishing run refuses to start unless `SITE_VISIBILITY=protected` (Vercel Deployment Protection), and `loopwatch-run.sh --preflight` shows each check.

```
~/.claude/projects/**/*.jsonl ┐
cowork session *.jsonl        ├─ collect (byte-offset watermarks, jq filter, secret scrub)
git repos (HEAD watermarks)   ┘        │
                                       ▼
                          claude -p prompts/extract.md
                          (headless; writes pages/*.html + run-meta.json to staging)
                                       │
                                       ▼
                          validate → dedup → install pages → digest →
                          manifest.json merge → git commit + push → Vercel
```

## Layout

```
loopwatch/
├── bin/loopwatch-run.sh      pipeline entrypoint (cron/launchd target)
├── bin/install.sh            launchd installer (default 21:30 daily)
├── bin/smoke-test.sh         end-to-end test with a stubbed claude CLI
├── lib/collect.sh            delta collection, watermarks, scrubbing
├── lib/publish.sh            validation, digest, manifest merge, commit
├── prompts/extract.md        the extraction agent — value bar lives here
├── site/index.html           static catalog shell (tree + search + digests)
├── site/manifest.json        single data source for the whole catalog
├── site/pages/YYYY/*.html    generated reference pages
├── site/digests/*.html       generated daily digests
├── state/watermarks.json     committed with content → atomic resume point
└── launchd/…plist            template used by install.sh
```

## Install

```sh
# 1. drop this directory into your HTML repo root, commit it
# 2. configure
cp loopwatch.conf.example loopwatch.conf
$EDITOR loopwatch.conf          # sources, GIT_REPOS, CLAUDE_BIN (absolute path: `which claude`)

# 3. verify sources resolve (esp. the Cowork glob — it's a best guess)
bin/loopwatch-run.sh --list-sources

# 4. first pass without publishing (keeps staging dir for inspection)
bin/loopwatch-run.sh --dry-run

# 5. schedule
bin/install.sh 21 30            # launchd, daily 21:30
# or: 30 21 * * * "/path/to/repo/loopwatch/bin/loopwatch-run.sh"
```

Deps: `bash`, `git`, `jq`, `claude` CLI. Written against macOS stock bash 3.2 (no flock, no assoc arrays, no GNU-only flags).

## Vercel wiring

Everything is static. If your project deploys the repo root, the catalog lands at `/loopwatch/site/`. Cleaner options: set `SITE_DIR` in the conf to your existing public dir (e.g. `$REPO/public/catalog`), or add a `vercel.json` rewrite. `index.html` fetches `manifest.json` relative to itself, so it works at any mount path.

## Semantics worth knowing

- **Watermarks** — transcripts by byte offset (append-only JSONL), git repos by HEAD sha. Advanced only after a successful run, and committed *with* the content they produced, so a crash never skips or double-publishes. Reset a single source by deleting its key from `state/watermarks.json`.
- **Dedup** — slug-level against the manifest; the extractor also sees `recent_slugs` in its context to avoid re-covering topics.
- **Empty days** — below `ACTIVITY_MIN_BYTES` of new delta, the run exits without invoking the model. With activity but nothing page-worthy, you still get the daily digest (that's the "summary of the day" page).
- **Failures** — non-zero exit leaves an autopsy (full staging dir incl. `claude-out.txt`) in `state/failed/`, keeps last 5. Watermarks don't advance, so the next run retries the same delta.
- **Concurrency** — mkdir lock; manual runs are safe any time.
- **Tuning the bar** — it's prose in `prompts/extract.md` ("would Marcus open this in 3 months?"). Too chatty → tighten the disqualifiers; too quiet → loosen. Model/cost knob is `MODEL` in the conf.

## Test

```sh
bin/smoke-test.sh   # full pipeline in a temp repo with a stubbed claude — no network, ~2s
```

Covers: collection + filtering, secret scrubbing (planted token must not survive), publish, manifest/digest integrity, empty-run skip, dry-run side-effect freedom, slug dedup.

## Ship loop

- `bin/ship.sh [patch|minor|major] ["msg"]` — the whole release cycle in one command: local e2e, `VERSION` bump, commit, tag, push. Actions (`ci.yml` + `release.yml`) then re-runs e2e on ubuntu **and** macos and publishes the GitHub release. `ci.yml` also runs weekly against zero changes to catch env rot.
- `bin/bootstrap-repo.sh [--codespace]` — one-shot repo creation (private, About, topics, first tag) from any machine with an authed `gh`; `--codespace` runs the e2e suite in a throwaway Codespace.
- `.devcontainer/` — every Codespace self-installs deps and runs the smoke test during create, so a green Codespace boot *is* a passing e2e run.

## Later: event-driven runs

The nightly batch is deliberate (it's what makes the digest coherent). If you want near-real-time pages too, add a Claude Code `SessionEnd` hook that kicks the same pipeline — the lock and watermarks make overlapping triggers harmless:

```json
{ "hooks": { "SessionEnd": [ { "hooks": [ { "type": "command",
  "command": "launchctl kickstart gui/$UID/com.marcuspatman.loopwatch" } ] } ] } }
```
