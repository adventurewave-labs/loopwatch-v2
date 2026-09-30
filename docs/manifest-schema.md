# `manifest.json` v1: public contract

`site/manifest.json` in the catalog repo is the single data source for the catalog UI. It is also the
**stable export contract** for other consumers, such as turbo-brain intake or Turbo Rig dashboards (R-15). loopwatch
only ever appends to it. Fields may be added in v1. Removing or renaming a field requires `version: 2`.

```jsonc
{
  "version": 1,                       // integer; bump only on breaking change
  "site_title": "Marcus — Engineering Catalog",
  "updated": "2026-09-26T03:30:12Z",  // UTC ISO-8601 of the last merge-bound run, or null
  "entries": [ /* Entry, oldest first */ ],
  "digests": [ /* Digest, newest first */ ]
}
```

## Entry: one reference page
| Field | Type | Notes |
|---|---|---|
| `slug` | string | `^[a-z0-9][a-z0-9-]{2,79}$`, unique across the catalog (dedup key) |
| `title` | string | < 200 chars |
| `category` | string | `^[a-z0-9-]+(/[a-z0-9-]+)?$`, at most two levels (`infra/kubernetes`) |
| `tags` | string[] | may be empty |
| `date` | string | `YYYY-MM-DD` (local date of the run that wrote it) |
| `path` | string | site-relative, `pages/<YYYY>/<slug>.html` |
| `summary` | string | 1–2 sentences |
| `source` | string | `claude-code:<project>`, `cowork:<topic>` or `git:<repo>`. May be empty |

## Digest: one per publishing run
| Field | Type | Notes |
|---|---|---|
| `date` | string | `YYYY-MM-DD` |
| `path` | string | `digests/<YYYY-MM-DD>[-HHMM].html` |
| `summary` | string | triage's 2–4 sentence day summary. If a redaction rule hit, it becomes the literal text `(digest summary withheld by loopwatch: redaction rule hit)` |
| `pages` | integer | pages published by that run |

## Guarantees for consumers
- Every `path` exists in the repo. The catalog repo's `catalog-check` CI enforces this.
- Pages are self-contained HTML with inline CSS only. They contain no `<script>`, `on*=` handlers, embeds, or external `src`/`href`/`url()`.
- Content has passed both the pre-model scrub and the post-extraction redaction scan (see the README's privacy section).
- Content reaches `main` only through a human-merged PR.

## Markdown export
`loopwatch run --export-md DIR` writes each page published by that run to `DIR/<slug>.md`, with this front-matter:

```yaml
---
slug: k8s-cronjob-queue-ingest
title: "Turbo-Flow ingest: CronJob + work queue"
category: infra/kubernetes
tags: ["k8s","turbo-flow"]
date: 2026-09-26
source: "claude-code:turbo-flow"
summary: "…"
catalog_path: pages/2026/k8s-cronjob-queue-ingest.html
generator: loopwatch
---
```

The body is a Markdown rendering of the page (headings, lists, fenced code). No turbo-brain code lives in
this repo. This file and the export are the whole seam.
