#!/usr/bin/env bash
# bootstrap-repo.sh — one-shot repo bootstrap from any machine with an authed `gh`.
# Creates the private repo, sets About + topics, pushes, tags the first release,
# and optionally runs the e2e suite in a throwaway Codespace.
# usage: bootstrap-repo.sh [--codespace]
set -euo pipefail

ORG="adventurewave-labs"
NAME="loopwatch"
DESC="Autonomous nightly loop: mines Claude Code/Cowork sessions and git activity into a static reference catalog with daily digests. bash + jq + claude -p, zero backend, Vercel-deployed."
TOPICS=(agentic claude-code automation knowledge-base static-site bash jq vercel)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

gh auth status >/dev/null

if ! git rev-parse --git-dir >/dev/null 2>&1; then
  git init -b main
  git add -A
  git commit -m "loopwatch: initial scaffold"
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$ORG/$NAME" --private --description "$DESC" --source . --remote origin --push
else
  git push -u origin main
fi

args=()
for t in "${TOPICS[@]}"; do args+=(--add-topic "$t"); done
gh repo edit "$ORG/$NAME" --description "$DESC" "${args[@]}"

V="v$(cat VERSION)"
if ! git rev-parse "$V" >/dev/null 2>&1; then
  git tag -a "$V" -m "loopwatch $V — initial release"
  git push origin "$V"          # release.yml: e2e gate, then publishes the release
fi

if [[ "${1:-}" == "--codespace" ]]; then
  CS="$(gh codespace create --repo "$ORG/$NAME" --branch main --idle-timeout 15m)"
  echo "codespace: $CS (postCreateCommand already runs the smoke test)"
  gh codespace ssh --codespace "$CS" -- 'cd /workspaces/loopwatch && ./bin/smoke-test.sh'
  gh codespace delete --codespace "$CS" --force
fi

echo "done: https://github.com/$ORG/$NAME"
