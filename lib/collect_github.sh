#!/usr/bin/env bash
# loopwatch lib — GitHub activity via the API (sourced; do not execute). R-8.
#
# Replaces v0.1's local-clone git collection: works with zero local repos.
# For each scope in GITHUB_SCOPES ("user:<login>" or "org:<org>"):
#   - commits authored by GITHUB_AUTHOR in the window          (search/commits)
#   - PRs authored by GITHUB_AUTHOR and merged in the window   (search/issues)
# The catalog repo is always excluded (loopwatch must never re-read its own output),
# and every repo must pass the same allowlist as transcripts, as "github:<owner>/<repo>".
# Window: (watermark, now - GITHUB_INDEX_LAG_MIN]. The lag keeps commits the search
# index has not caught up on inside the next window instead of losing them.
# The watermark advances only when every query succeeded and nothing was truncated.

gh_iso_now()      { jq -nr --argjson m "${1:-0}" '(now - ($m * 60)) | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
gh_iso_hours_ago() { jq -nr --argjson h "$1" '(now - ($h * 3600)) | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

# gh_search <endpoint> <query> -> all items (up to GITHUB_MAX_PAGES x 100) as one JSON doc.
# Returns 1 on API failure, 2 if results were truncated.
gh_search() {
  local ep="$1" q="$2" page=1 acc='[]' body total n
  while [[ "$page" -le "${GITHUB_MAX_PAGES:-5}" ]]; do
    body="$("$GH_BIN" api -X GET "$ep" -f q="$q" -f per_page=100 -f page="$page" 2>/dev/null)" || return 1
    acc="$(jq -c --argjson a "$acc" '$a + (.items // [])' <<< "$body")" || return 1
    total="$(jq -r '.total_count // 0' <<< "$body")"
    n="$(jq 'length' <<< "$acc")"
    GH_SEARCH_RESULT="$acc"
    [[ "$n" -lt "$total" && "$(jq '(.items // []) | length' <<< "$body")" -eq 100 ]] || return 0
    page=$((page + 1))
  done
  return 2
}

collect_github() {
  local since until author scope safe out ok=true commits prs rc repos repo allowed
  [[ "${#GITHUB_SCOPES[@]}" -gt 0 ]] || return 0
  until="$(gh_iso_now "$GITHUB_INDEX_LAG_MIN")"
  since="$(jq -r '.github.since // empty' "$WATERMARKS")"
  [[ -n "$since" ]] || since="$(gh_iso_hours_ago "$FIRST_RUN_LOOKBACK_HOURS")"
  author="${GITHUB_AUTHOR:-}"
  if [[ -z "$author" ]]; then
    author="$("$GH_BIN" api user 2>/dev/null | jq -r '.login // empty' 2>/dev/null || true)"
  fi
  if [[ -z "$author" ]]; then
    log "WARN: GitHub source skipped — could not resolve GITHUB_AUTHOR (is gh authenticated?)"
    return 0
  fi

  for scope in "${GITHUB_SCOPES[@]}"; do
    safe="$(printf '%s' "$scope" | sed 's/[^A-Za-z0-9_-]/-/g')"
    out="$RUN_DIR/bundle/git/github-${safe}.log"

    rc=0; gh_search search/commits "$scope author:$author -repo:$CATALOG_REPO committer-date:$since..$until" || rc=$?
    if [[ "$rc" -eq 1 ]]; then log "WARN: GitHub commit search failed for $scope — window retried next run"; ok=false; continue; fi
    if [[ "$rc" -eq 2 ]]; then log "WARN: GitHub commit search truncated for $scope — window retried next run"; ok=false; fi
    commits="$GH_SEARCH_RESULT"
    rc=0; gh_search search/issues "$scope is:pr is:merged author:$author -repo:$CATALOG_REPO merged:$since..$until" || rc=$?
    if [[ "$rc" -eq 1 ]]; then log "WARN: GitHub PR search failed for $scope — window retried next run"; ok=false; continue; fi
    if [[ "$rc" -eq 2 ]]; then log "WARN: GitHub PR search truncated for $scope — window retried next run"; ok=false; fi
    prs="$GH_SEARCH_RESULT"

    # allowlist per repo (same INCLUDE/EXCLUDE_PROJECTS as transcripts, label "github")
    repos="$( { jq -r '.[].repository.full_name // empty' <<< "$commits"
                jq -r '.[].repository_url // empty | sub("^.*/repos/"; "")' <<< "$prs"; } | sort -u)"
    allowed='[]'
    while IFS= read -r repo; do
      [[ -n "$repo" ]] || continue
      if [[ "$repo" == "$CATALOG_REPO" ]]; then continue; fi
      if project_allowed github "$repo"; then allowed="$(jq -c --arg r "$repo" '. + [$r]' <<< "$allowed")"; fi
    done <<< "$repos"

    {
      echo "=== github: $scope · $since .. $until ==="
      jq -r --argjson ok "$allowed" '
        map(select((.repository.full_name // "") as $r | $ok | index($r)))
        | sort_by(.commit.committer.date) | .[]
        | "commit " + (.repository.full_name // "?") + " " + (.sha // "")[0:7] + " "
          + ((.commit.committer.date // "")[0:10]) + "  "
          + ((.commit.message // "") | split("\n")[0] | .[0:200])' <<< "$commits" 2>/dev/null
      jq -r --argjson ok "$allowed" '
        map(select((.repository_url // "" | sub("^.*/repos/"; "")) as $r | $ok | index($r)))
        | .[]
        | "PR merged " + ((.repository_url // "") | sub("^.*/repos/"; "")) + "#" + ((.number // 0) | tostring)
          + " " + ((.closed_at // "")[0:10]) + "  " + ((.title // "") | .[0:200])
          + (if (.body // "") != "" then "\n    " + ((.body // "") | gsub("\\s+"; " ") | .[0:600]) else "" end)' <<< "$prs" 2>/dev/null
    } | head -c "$((MAX_FILE_KB * 1024))" | scrub_all > "$out"
    if [[ "$( { grep -v '^=== ' "$out" || true; } | wc -c | tr -d ' ')" -lt 20 ]]; then
      rm -f "$out"
    else
      printf '%s\t%s\n' "$(now_epoch)" "bundle/git/github-${safe}.log" >> "$RUN_DIR/bundle-index.tsv"
    fi
  done

  if [[ "$ok" == "true" ]]; then
    jq --arg v "$until" '.github.since = $v' "$RUN_DIR/new-watermarks.json" > "$RUN_DIR/nw.tmp" \
      && mv "$RUN_DIR/nw.tmp" "$RUN_DIR/new-watermarks.json"
  fi
}

list_github_sources() {
  local scope
  echo "— GitHub sources (author: ${GITHUB_AUTHOR:-<gh api user>}, since: $(jq -r '.github.since // "first run"' "$WATERMARKS")) —"
  if [[ "${#GITHUB_SCOPES[@]}" -eq 0 ]]; then echo "  (off: GITHUB_SCOPES=())"; return; fi
  for scope in "${GITHUB_SCOPES[@]}"; do echo "  $scope  (repos must match INCLUDE_PROJECTS as github:<owner>/<repo>; $CATALOG_REPO always excluded)"; done
}
