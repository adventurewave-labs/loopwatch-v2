#!/usr/bin/env bash
# loopwatch lib — GitHub activity via the API (sourced; do not execute). R-8.
#
# Replaces v0.1's local-clone git collection: works with zero local repos.
# For each scope in GITHUB_SCOPES ("user:<login>" or "org:<org>"):
#   - commits authored by GITHUB_AUTHOR since the watermark   (search/commits)
#   - pull requests merged since the watermark                (search/issues)
# Watermark: .github.since (UTC ISO-8601) in watermarks.json. It advances to this
# run's start time only when every query succeeded; a failed query retries next run.

gh_iso_now()      { jq -nr 'now | strftime("%Y-%m-%dT%H:%M:%SZ")'; }
gh_iso_hours_ago() { jq -nr --argjson h "$1" '(now - ($h * 3600)) | strftime("%Y-%m-%dT%H:%M:%SZ")'; }

collect_github() {
  local scopes_n since until author scope safe out ok=true commits prs
  scopes_n="${#GITHUB_SCOPES[@]}"
  [[ "$scopes_n" -gt 0 ]] || return 0
  until="$(gh_iso_now)"
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
    if ! commits="$("$GH_BIN" api -X GET search/commits \
          -f q="$scope author:$author committer-date:>$since" \
          -f sort=committer-date -f order=desc -f per_page=100 2>/dev/null)"; then
      log "WARN: GitHub commit search failed for $scope — will retry this window next run"
      ok=false; continue
    fi
    if ! prs="$("$GH_BIN" api -X GET search/issues \
          -f q="$scope is:pr is:merged merged:>$since" \
          -f sort=updated -f order=desc -f per_page=50 2>/dev/null)"; then
      log "WARN: GitHub PR search failed for $scope — will retry this window next run"
      ok=false; continue
    fi
    {
      echo "=== github: $scope · since $since ==="
      printf '%s' "$commits" | jq -r '
        (.items // []) | sort_by(.commit.committer.date) | .[]
        | "commit " + (.repository.full_name // "?") + " " + (.sha // "")[0:7] + " "
          + ((.commit.committer.date // "")[0:10]) + "  "
          + ((.commit.message // "") | split("\n")[0] | .[0:200])' 2>/dev/null
      printf '%s' "$prs" | jq -r '
        (.items // []) | .[]
        | "PR merged " + ((.repository_url // "") | sub("^.*/repos/"; "")) + "#" + ((.number // 0) | tostring)
          + " " + ((.closed_at // "")[0:10]) + "  " + ((.title // "") | .[0:200])
          + (if (.body // "") != "" then "\n    " + ((.body // "") | gsub("\\s+"; " ") | .[0:600]) else "" end)' 2>/dev/null
    } | head -c "$((MAX_FILE_KB * 1024))" | scrub_all > "$out"
    if [[ "$(grep -v '^=== ' "$out" | wc -c | tr -d ' ')" -lt 20 ]]; then
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
  for scope in ${GITHUB_SCOPES[@]+"${GITHUB_SCOPES[@]}"}; do echo "  $scope"; done
}
