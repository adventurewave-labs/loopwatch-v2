#!/usr/bin/env bash
# loopwatch lib — delta collection (sourced by loopwatch-run.sh; do not execute)
# Contract: fills $STAGING/bundle/{transcripts,git}/ + bundle/context.json,
# and writes advanced offsets to $STAGING/new-watermarks.json (applied only on success).

# Best-effort credential scrub before anything reaches the model or the repo.
scrub() {
  sed -E \
    -e 's/sk-[A-Za-z0-9_-]{16,}/[REDACTED:key]/g' \
    -e 's/(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}/[REDACTED:github]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[REDACTED:github]/g' \
    -e 's/AKIA[0-9A-Z]{16}/[REDACTED:aws]/g' \
    -e 's/xox[baprs]-[A-Za-z0-9-]{10,}/[REDACTED:slack]/g' \
    -e 's/eyJ[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{15,}\.[A-Za-z0-9_-]{10,}/[REDACTED:jwt]/g' \
    -e 's/-----BEGIN [A-Z ]*PRIVATE KEY-----/[REDACTED:pem]/g'
}

# JSONL transcript -> readable "[role] text" lines; drops tool-call noise.
# Tolerant of schema drift: unparseable lines are silently skipped.
filter_transcript() {
  jq -r '
    select(.type == "user" or .type == "assistant")
    | .message as $m
    | (($m.content // empty)
       | if type == "string" then .
         else ([ .[]? | select(.type? == "text") | .text ] | join("\n"))
         end) as $t
    | select(($t // "") | length > 2)
    | "[" + ($m.role // .type) + "] " + $t
  ' 2>/dev/null || true
}

# collect_globs <label> <glob>...
collect_globs() {
  local label="$1"; shift
  local pat f size old out n=0
  for pat in "$@"; do
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      size="$(wc -c < "$f" | tr -d ' ')"
      old="$(jq -r --arg k "$f" '.files[$k] // 0' "$WATERMARKS")"
      if [[ "$size" -le "$old" ]]; then
        continue
      fi
      n=$((n + 1))
      out="$STAGING/bundle/transcripts/${label}-${n}.txt"
      {
        echo "=== source: $f (bytes ${old}..${size}) ==="
        # delta only; keep the most recent MAX_FILE_KB after filtering
        tail -c "+$((old + 1))" "$f" | filter_transcript | scrub | tail -c "$((MAX_FILE_KB * 1024))"
      } > "$out"
      # drop if filtering left nothing beyond the header
      if [[ "$(wc -c < "$out" | tr -d ' ')" -lt 250 ]]; then
        rm -f "$out"
      fi
      jq --arg k "$f" --argjson v "$size" '.files[$k] = $v' \
        "$STAGING/new-watermarks.json" > "$STAGING/nw.tmp" \
        && mv "$STAGING/nw.tmp" "$STAGING/new-watermarks.json"
    done < <(compgen -G "$pat" || true)
  done
}

collect_git() {
  local repo name head last out
  for repo in ${GIT_REPOS[@]+"${GIT_REPOS[@]}"}; do
    if [[ ! -d "$repo/.git" ]]; then
      log "git source missing, skipping: $repo"
      continue
    fi
    name="$(basename "$repo")"
    head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || true)"
    [[ -n "$head" ]] || continue
    last="$(jq -r --arg k "$repo" '.git[$k] // ""' "$WATERMARKS")"

    local patch_args=""
    if [[ "$GIT_INCLUDE_PATCH" == "true" ]]; then
      patch_args="-p --unified=2"
    fi

    out="$STAGING/bundle/git/${name}.log"
    {
      echo "=== repo: $repo ==="
      if [[ -n "$last" ]] && git -C "$repo" cat-file -e "$last" 2>/dev/null; then
        # shellcheck disable=SC2086
        { git -C "$repo" log "${last}..HEAD" --stat --date=short --format='%h %ad %s' $patch_args 2>/dev/null || true; } \
          | head -c "$((MAX_FILE_KB * 1024))"
      else
        # first run for this repo (or rewritten history): last 48h
        # shellcheck disable=SC2086
        { git -C "$repo" log --since=48.hours --stat --date=short --format='%h %ad %s' $patch_args 2>/dev/null || true; } \
          | head -c "$((MAX_FILE_KB * 1024))"
      fi
    } | scrub > "$out"
    if [[ "$(wc -c < "$out" | tr -d ' ')" -lt 120 ]]; then
      rm -f "$out"
    fi
    jq --arg k "$repo" --arg v "$head" '.git[$k] = $v' \
      "$STAGING/new-watermarks.json" > "$STAGING/nw.tmp" \
      && mv "$STAGING/nw.tmp" "$STAGING/new-watermarks.json"
  done
}

write_context() {
  jq -n \
    --arg date "$RUN_DATE" \
    --arg title "$(jq -r '.site_title // "Catalog"' "$MANIFEST")" \
    --argjson cats "$(jq '[.entries[].category] | unique' "$MANIFEST")" \
    --argjson slugs "$(jq '[.entries[-200:][].slug]' "$MANIFEST")" \
    '{run_date: $date, site_title: $title, existing_categories: $cats, recent_slugs: $slugs}' \
    > "$STAGING/bundle/context.json"
}

collect_all() {
  cp "$WATERMARKS" "$STAGING/new-watermarks.json"
  collect_globs "claude-code" ${CLAUDE_CODE_GLOBS[@]+"${CLAUDE_CODE_GLOBS[@]}"}
  collect_globs "cowork"      ${COWORK_GLOBS[@]+"${COWORK_GLOBS[@]}"}
  collect_git
  write_context
}

has_activity() {
  local bytes
  bytes="$(find "$STAGING/bundle/transcripts" "$STAGING/bundle/git" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' ')"
  [[ "${bytes:-0}" -ge "$ACTIVITY_MIN_BYTES" ]]
}

list_sources() {
  local pat f size old repo
  echo "— transcript sources —"
  for pat in ${CLAUDE_CODE_GLOBS[@]+"${CLAUDE_CODE_GLOBS[@]}"} ${COWORK_GLOBS[@]+"${COWORK_GLOBS[@]}"}; do
    echo "glob: $pat"
    local found=0
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      found=1
      size="$(wc -c < "$f" | tr -d ' ')"
      old="$(jq -r --arg k "$f" '.files[$k] // 0' "$WATERMARKS")"
      printf '  %10sB total  %10sB new   %s\n' "$size" "$((size - old))" "$f"
    done < <(compgen -G "$pat" || true)
    if [[ "$found" -eq 0 ]]; then echo "  (no matches)"; fi
  done
  echo "— git sources —"
  for repo in ${GIT_REPOS[@]+"${GIT_REPOS[@]}"}; do
    if [[ -d "$repo/.git" ]]; then echo "  ok       $repo"; else echo "  MISSING  $repo"; fi
  done
}
