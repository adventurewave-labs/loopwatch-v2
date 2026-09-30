# loopwatch-catalog

The private reference catalog written by [loopwatch](https://github.com/adventurewave-labs/loopwatch-v2).

- **Who writes it:** loopwatch opens one PR at a time (`loopwatch/<date>-<time>`). While that PR is open, later runs add to it. Nothing is pushed to `main` directly.
- **How to review:** read the PR diff, or open its Railway PR environment if PR deploys are on. Merge to publish, close to discard.
- **Where it's served:** Railway, from `main`. `server.js` is a zero-dependency Node server that serves `site/` behind HTTP Basic Auth.
  - It **fails closed**: until `CATALOG_USER` and `CATALOG_PASSWORD` are set on the Railway service, every page returns 503. Only `/healthz` is open.
  - It adds a strict CSP (`script-src 'self'`), `noindex` and `no-referrer`, and blocks path traversal.
- **Data contract:** `site/manifest.json` v1. See `docs/manifest-schema.md` in the loopwatch repo.
- **CI (`catalog-check`):**
  - validates the manifest and checks that every path it lists exists;
  - rejects script or embed markup in generated pages;
  - runs `test/server.test.sh`, which checks the fail-closed behaviour, auth and traversal blocking.

Hand edits are fine. To remove a page, delete it, remove its `entries[]` row from the manifest, and merge.
