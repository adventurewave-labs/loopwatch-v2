# PRD: loopwatch (v0.1.0, retroactive)

> Superseded for current work by [`PRD-v0.2.md`](PRD-v0.2.md). Kept as the v0.1 record.

Version: v0.1.0 | Date: 2026-07-06 | Owner: Marcus Patman | Status: shipped, retroactive formalization of the kickoff spec

## Problem

Engineering signal - architecture decisions, non-obvious fixes, reusable artifacts - is generated daily across Claude Code sessions, Cowork sessions, and git activity, then evaporates in transcripts. Marcus already publishes hand-made HTML reference pages through a repo-to-Vercel pipeline; the missing piece is an autonomous loop that watches activity and feeds that pipeline without human effort.

## Goal

A fully unattended nightly loop: mine activity deltas, extract items of durable reference value, publish self-contained HTML pages plus a daily digest into a static catalog, git push, Vercel deploys. Zero manual steps after install.

## Key decisions (locked at kickoff)

- Runtime: launchd/cron plus headless claude -p on the workstation. Only place with direct access to ~/.claude/projects transcripts and local repo clones.
- Sources: Claude Code JSONL transcripts, Cowork session transcripts, git commit deltas across watched repos.
- Deliverable: self-contained drop-in scaffold; the repo is the scaffold.
- UI: both requested views over one manifest.json - a collapsible category tree with client-side search, and dated digest pages. Resolves the tree-vs-digest question by shipping both from a single data source.
- No backend: the pipeline emits static artifacts only; Vercel serves them.

## Functional requirements

1. Watermarked incremental collection: byte offsets per transcript file, HEAD sha per git repo. Watermarks advance only on successful runs and are committed atomically with the content they produced.
2. Credential scrubbing before content leaves the machine - GitHub, AWS, Slack, OpenAI token patterns, JWTs, PEM headers - plus a prompt-level redaction rule as second layer.
3. Extraction bar: would Marcus open this page in three months. Zero pages is a valid outcome; typical yield 0-3 per day. Never pad.
4. Validation firewall between model output and publish: schema-checked run-meta.json, slug regex, HTML self-containment check, slug dedup against the manifest.
5. A daily digest page whenever there was activity, linked from the catalog and recorded in the manifest.
6. Operability: failure autopsies (staging preserved, last 5), single-instance lock, dry-run and list-sources modes, log retention.
7. End-to-end testable with no network and no real model via a stubbed claude CLI.

## Non-goals (v0.1)

Real-time processing (nightly batch is the design center), multi-user catalogs, dynamic search backends, editing UI.

## Risks

- Transcript-derived pages reach the public web; scrubbing is best-effort. Mitigation: Vercel Deployment Protection, private project.
- Cowork transcript storage layout is an assumption; list-sources verifies before install.
- Stock macOS constraints (bash 3.2, BSD userland, no flock). Mitigation: 3.2-safe constructs and a macos-latest CI gate.

## Shipped in v0.1.0

Pipeline (bin/loopwatch-run.sh, lib/collect.sh, lib/publish.sh), extraction prompt, static catalog UI, digest generator, launchd installer, e2e smoke test, CI on ubuntu and macos plus shellcheck, release loop (bin/ship.sh, tag-gated release workflow), devcontainer, one-shot bootstrap script.

## Roadmap

SessionEnd hook for near-real-time pages; cross-day pattern learning; category curation pass; full-text search over page bodies.
