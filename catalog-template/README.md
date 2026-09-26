# loopwatch-catalog

This repo holds the private reference catalog written by [loopwatch](https://github.com/adventurewave-labs/loopwatch-v2). It contains `site/` only.

- **Who writes it:** loopwatch, one PR per day (`loopwatch/<date>`). While that PR is open, later runs add to it. Nothing is pushed to `main` directly.
- **How to review:** open the PR's Vercel preview. The project is behind Vercel Deployment Protection. Merge to publish, close to discard.
- **Where it's served:** the Vercel project `loopwatch-catalog`, with Deployment Protection on production and previews. `vercel.json` adds a strict CSP (`script-src 'self'`), `noindex`, and `no-referrer`.
- **Data contract:** `site/manifest.json` v1. See `docs/manifest-schema.md` in the loopwatch repo.
- **CI:** `catalog-check` validates the manifest, checks that every path it lists exists, and rejects any page with script or embed markup.

Hand edits are fine. Edit a page or delete one, remove its `entries[]` row from the manifest, and merge.
