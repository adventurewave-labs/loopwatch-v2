#!/usr/bin/env bash
# loopwatch lib — catalog working clone + PR publishing (sourced; do not execute). R-9.
#
# The catalog is a separate private repo (CATALOG_REPO) holding site/ only. loopwatch
# keeps a tool-managed clone under $STATE_DIR/catalog — not a dev checkout; it is reset
# freely. Each run commits to a loopwatch/<date>-<time> branch and opens (or updates) one PR.
# There is at most one open loopwatch PR: while it is unmerged, later runs keep adding
# to it, so two PRs never fight over manifest.json. Nothing is ever pushed to CATALOG_BASE.

catalog_git() { git -C "$CATALOG_DIR" "$@"; }

# open loopwatch PR as "<number>\t<headRefName>", or nothing. Fails (non-zero) if
# gh cannot answer: guessing "no open PR" would open a second one.
open_loopwatch_pr() {
  local json
  json="$("$GH_BIN" pr list --repo "$CATALOG_REPO" --state open --base "$CATALOG_BASE" \
            --json number,headRefName --limit 50 2>/dev/null)" || return 1
  jq -r '[.[] | select(.headRefName | startswith("loopwatch/"))] | sort_by(.number) | last
         | select(. != null) | "\(.number)\t\(.headRefName)"' <<< "$json" || return 1
}

# ensure_catalog: clone if needed, fetch, and check out the branch this run writes to.
# Sets CATALOG_BRANCH, CATALOG_PR (may be empty), SITE_DIR, MANIFEST.
ensure_catalog() {
  local pr
  if [[ ! -d "$CATALOG_DIR/.git" ]]; then
    log "cloning catalog $CATALOG_REPO -> $CATALOG_DIR"
    mkdir -p "$(dirname "$CATALOG_DIR")"
    "$GH_BIN" repo clone "$CATALOG_REPO" "$CATALOG_DIR" -- -q >/dev/null 2>&1 \
      || { DIE_REASON=catalog_clone_failed; die "could not clone $CATALOG_REPO (gh auth? repo exists?)"; }
  fi
  catalog_git config user.name  >/dev/null 2>&1 || catalog_git config user.name  "loopwatch"
  catalog_git config user.email >/dev/null 2>&1 || catalog_git config user.email "loopwatch@localhost"
  catalog_git fetch -q --prune origin \
    || { DIE_REASON=catalog_fetch_failed; die "git fetch failed for the catalog clone"; }

  pr="$(open_loopwatch_pr)" \
    || { DIE_REASON=gh_pr_list_failed; die "could not list open PRs on $CATALOG_REPO (fail closed: never risk a second PR)"; }
  CATALOG_PR="$(printf '%s' "$pr" | cut -f1)"
  if [[ -n "$pr" ]] && catalog_git rev-parse -q --verify "origin/$(printf '%s' "$pr" | cut -f2)" >/dev/null; then
    # an open PR exists: keep adding to it
    CATALOG_BRANCH="$(printf '%s' "$pr" | cut -f2)"
    catalog_git checkout -q -B "$CATALOG_BRANCH" "origin/$CATALOG_BRANCH"
    log "catalog: adding to open PR #$CATALOG_PR ($CATALOG_BRANCH)"
  else
    # no open PR: always start fresh from the base. A branch left behind by a PR you
    # closed is never reused, so closing a PR really discards its content.
    CATALOG_PR=""
    CATALOG_BRANCH="loopwatch/${RUN_TS//_/-}"
    catalog_git checkout -q -B "$CATALOG_BRANCH" "origin/$CATALOG_BASE"
  fi
  catalog_git reset -q --hard
  catalog_git clean -qfd
  # keep the branch current with the base so the PR merges cleanly; on conflict leave it to review
  if ! catalog_git rebase -q "origin/$CATALOG_BASE" >/dev/null 2>&1; then
    catalog_git rebase --abort >/dev/null 2>&1 || true
    log "WARN: catalog branch does not rebase cleanly on $CATALOG_BASE — PR will need a manual merge"
  fi

  SITE_DIR="$CATALOG_DIR/site"
  MANIFEST="$SITE_DIR/manifest.json"
  [[ -f "$MANIFEST" ]] || { DIE_REASON=no_manifest; die "catalog has no site/manifest.json (seed it from this repo's site/)"; }
}

# push_and_pr: push the run branch and open the PR if none is open. Never touches the base.
push_and_pr() {
  local title body url
  case "$CATALOG_BRANCH" in
    loopwatch/*) ;;
    *) DIE_REASON=bad_branch; die "refusing to push non-loopwatch branch '$CATALOG_BRANCH'" ;;
  esac
  [[ "$CATALOG_BRANCH" != "$CATALOG_BASE" ]] || { DIE_REASON=bad_branch; die "refusing to push to $CATALOG_BASE"; }

  catalog_git push -q --force-with-lease origin "HEAD:refs/heads/$CATALOG_BRANCH" \
    || { DIE_REASON=push_failed; die "push of $CATALOG_BRANCH failed (watermarks not advanced)"; }

  if [[ -n "$CATALOG_PR" ]]; then
    "$GH_BIN" pr comment "$CATALOG_PR" --repo "$CATALOG_REPO" \
      --body "loopwatch run $RUN_TS added ${INSTALLED_PAGES:-0} page(s) and a digest." >/dev/null 2>&1 \
      || log "WARN: could not comment on PR #$CATALOG_PR (the push landed)"
    log "catalog: updated PR #$CATALOG_PR"
    return 0
  fi

  title="loopwatch: $RUN_DATE — ${INSTALLED_PAGES:-0} page(s) + digest"
  body="$(jq -r --arg cost "$(usage_cost)" '
      "## Digest\n\n" + .digest_summary + "\n\n"
      + (if (.highlights // []) | length > 0 then "**Highlights**\n" + ((.highlights // []) | map("- " + .) | join("\n")) + "\n\n" else "" end)
      + "## Pages\n\n"
      + (if (.pages | length) == 0 then "_None: nothing cleared the reference bar._\n"
         else (.pages | map("- **" + .title + "** (`" + .category + "`) — " + .summary) | join("\n")) + "\n" end)
      + "\nReview in the protected Vercel preview for this PR. Merge to publish; close to discard.\n\n"
      + "<sub>model cost this run: $" + $cost + " · generated by loopwatch</sub>"
      | gsub("@"; "@\u200b")' "$RUN_DIR/meta-final.json")"
  if url="$("$GH_BIN" pr create --repo "$CATALOG_REPO" --base "$CATALOG_BASE" --head "$CATALOG_BRANCH" \
             --title "$title" --body "$body" 2>/dev/null)"; then
    CATALOG_PR_URL="$url"
    log "catalog: opened PR $url"
  else
    log "WARN: branch pushed but 'gh pr create' failed — open a PR for $CATALOG_BRANCH by hand"
  fi
}
