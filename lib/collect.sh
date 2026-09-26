#!/usr/bin/env bash
# loopwatch lib — delta collection (sourced by loopwatch-run.sh; do not execute)
# Contract: fills $RUN_DIR/bundle/{transcripts,git}/ (git/ = GitHub API, lib/collect_github.sh) + bundle/context.json, records each
# bundle file's source age in $RUN_DIR/bundle-index.tsv, and writes advanced offsets to
# $RUN_DIR/new-watermarks.json (applied only after a successful publish or skip).
#
# Watermark state is keyed by hash_key(<absolute path>) — never the path itself (bug 7).

# Scrubbing (secrets + redact.list) lives in lib/redact.sh: scrub_all.

# JSONL transcript -> readable "[role] text" lines; drops tool-call noise.
# Claude Code 2.1.x schema (docs/revival-notes.md): drops isMeta (harness-injected)
# and isSidechain (subagent) lines, lines whose cwd is loopwatch's own run dir
# (second self-ingestion guard), and inline <system-reminder> blocks.
# Tool calls are kept as one compact "[tool:Name] <command/path>" line each (tool
# RESULTS are always dropped): in agentic sessions most of the work is tool calls, and
# a text-only filter keeps ~0.1% of the transcript. INCLUDE_TOOL_CALLS=false restores v0.1.
# Tolerant of schema drift: each line is parsed on its own, so one malformed line is
# skipped without losing the rest of the delta.
filter_transcript() {
  jq -R -r --arg rundir "$RUN_DIR" --arg tools "${INCLUDE_TOOL_CALLS:-true}" '
    def tool_line:
      "[tool:" + (.name // "?") + "] "
      + ((.input // {}) | (.command // .file_path // .path // .url // .pattern // .query // .description // .prompt
                           // (tostring)) | tostring | gsub("\\s+"; " ") | .[0:200]);
    (fromjson? // empty)
    | select(type == "object")
    | select(.type == "user" or .type == "assistant")
    | select((.isMeta // false) != true and (.isSidechain // false) != true)
    | select(((.cwd // "") | (. == $rundir or endswith("/loopwatch/run"))) | not)
    | .message as $m
    | (($m.content // empty)
       | if type == "string" then .
         else ([ .[]? | if .type? == "text" then .text
                        elif .type? == "tool_use" and $tools == "true" then tool_line
                        else empty end ] | join("\n"))
         end)
    | gsub("(?s)<system-reminder>.*?</system-reminder>"; "")
    | gsub("^\\s+|\\s+$"; "") as $t
    | select(($t | length) > 2)
    | "[" + ($m.role // "unknown") + "] " + $t
  ' 2>/dev/null || true
}

# Project dirs loopwatch must never read: its own run dir (v0.2) and v0.1 mktemp dirs.
is_self_project() {
  local dir="$1" enc
  enc="$(encode_project_dir "$RUN_DIR")"
  case "$dir" in
    "$enc"|*-loopwatch-run) return 0 ;;
    *loopwatch-[A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9][A-Za-z0-9]) return 0 ;;
  esac
  return 1
}

# Allowlist (R-7). A pattern containing ':' matches "<label>:<project-dir>"
# (e.g. "cowork:*"), otherwise it matches the project dir name alone
# (e.g. "*-src-turbo-flow"). Empty INCLUDE_PROJECTS = collect nothing.
# EXCLUDE_PROJECTS always wins.
# shellcheck disable=SC2053  # unquoted RHS is intentional: glob matching
project_allowed() {
  local label="$1" dir="$2" p key hit=1
  key="$label:$dir"
  for p in ${INCLUDE_PROJECTS[@]+"${INCLUDE_PROJECTS[@]}"}; do
    case "$p" in
      *:*) if [[ "$key" == $p ]]; then hit=0; break; fi ;;
      *)   if [[ "$dir" == $p ]]; then hit=0; break; fi ;;
    esac
  done
  [[ "$hit" -eq 0 ]] || return 1
  for p in ${EXCLUDE_PROJECTS[@]+"${EXCLUDE_PROJECTS[@]}"}; do
    case "$p" in
      *:*) if [[ "$key" == $p ]]; then return 1; fi ;;
      *)   if [[ "$dir" == $p ]]; then return 1; fi ;;
    esac
  done
  return 0
}

wm_get() { jq -r --arg k "$1" '.files[$k] // empty' "$WATERMARKS"; }
wm_set() {
  jq --arg k "$1" --argjson v "$2" '.files[$k] = $v' \
    "$RUN_DIR/new-watermarks.json" > "$RUN_DIR/nw.tmp" \
    && mv "$RUN_DIR/nw.tmp" "$RUN_DIR/new-watermarks.json"
}

# decide_source <label> <file>: echoes "skip:<reason>" or "ok"
decide_source() {
  local dir
  dir="$(basename "$(dirname "$2")")"
  if is_self_project "$dir"; then echo "skip:self"; return; fi
  if ! project_allowed "$1" "$dir"; then echo "skip:not-allowlisted"; return; fi
  echo "ok"
}

# collect_globs <label> <glob>...
collect_globs() {
  local label="$1"; shift
  local pat f key size old chunk len partial consumed out n=0 cwd proj sess now decision
  now="$(now_epoch)"
  for pat in "$@"; do
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      decision="$(decide_source "$label" "$f")"
      [[ "$decision" == "ok" ]] || continue
      key="$(hash_key "$f")"
      size="$(file_size "$f")"
      old="$(wm_get "$key")"

      if [[ -z "$old" ]]; then
        # first sighting: only files touched within FIRST_RUN_LOOKBACK_HOURS are mined
        # from the start; older history is watermarked at its current size and skipped.
        if [[ $(( now - $(file_mtime "$f") )) -gt $(( FIRST_RUN_LOOKBACK_HOURS * 3600 )) ]]; then
          wm_set "$key" "$size"
          continue
        fi
        old=0
      fi
      if [[ "$size" -lt "$old" ]]; then
        log "source shrank (truncated/rotated) — re-reading from 0: $label:$key"   # bug 4
        old=0
      fi
      [[ "$size" -gt "$old" ]] || continue

      # Take the delta, then stop at the last complete line so a session that is
      # still being written never loses its trailing partial JSON line (bug 3).
      chunk="$RUN_DIR/chunk.tmp"
      tail -c "+$((old + 1))" "$f" > "$chunk"
      len="$(file_size "$chunk")"
      if [[ "$len" -gt 0 ]] && [[ "$(tail -c 1 "$chunk" | od -An -c | tr -d ' ')" != '\n' ]]; then
        partial="$(tail -n 1 "$chunk" | wc -c | tr -d ' ')"
        consumed=$(( len - partial ))
      else
        consumed="$len"
      fi
      if [[ "$consumed" -le 0 ]]; then
        rm -f "$chunk"
        continue
      fi

      cwd="$(head -c "$consumed" "$chunk" | jq -R -r 'fromjson? | objects | select(.cwd != null) | .cwd' 2>/dev/null | head -1 || true)"
      proj="$(basename "${cwd:-unknown}")"
      sess="$(basename "$f" .jsonl | cut -c1-8)"
      n=$((n + 1))
      out="$RUN_DIR/bundle/transcripts/${label}-${n}.txt"
      {
        echo "=== source: ${label}:${proj} · session ${sess} ==="
        # delta only; keep the most recent MAX_FILE_KB after filtering
        head -c "$consumed" "$chunk" | filter_transcript | tail -c "$((MAX_FILE_KB * 1024))"
      } | scrub_all > "$out"
      rm -f "$chunk"
      # drop if filtering left nothing beyond the header
      if [[ "$( { grep -v '^=== ' "$out" || true; } | wc -c | tr -d ' ')" -lt 20 ]]; then
        rm -f "$out"
      else
        printf '%s\t%s\n' "$(file_mtime "$f")" "bundle/transcripts/${label}-${n}.txt" >> "$RUN_DIR/bundle-index.tsv"
      fi
      wm_set "$key" "$((old + consumed))"
    done < <(compgen -G "$pat" | LC_ALL=C sort || true)
  done
}

# Hard cap on the whole bundle (R-1, bug 2): drop the oldest content first until
# the bundle fits MAX_BUNDLE_KB. Whole files go first; the boundary file keeps its tail.
trim_bundle() {
  local cap total excess ts rel f size keep hdr
  cap=$(( MAX_BUNDLE_KB * 1024 ))
  TRIMMED_BYTES=0
  total="$(bundle_bytes)"
  [[ "$total" -gt "$cap" ]] || return 0
  excess=$(( total - cap ))
  while IFS=$'\t' read -r ts rel; do
    [[ "$excess" -gt 0 ]] || break
    f="$RUN_DIR/$rel"
    [[ -f "$f" ]] || continue
    size="$(file_size "$f")"
    if [[ "$size" -le "$excess" ]]; then
      rm -f "$f"
      excess=$(( excess - size ))
      TRIMMED_BYTES=$(( TRIMMED_BYTES + size ))
    else
      hdr="$(head -n 1 "$f")"
      keep=$(( size - excess - ${#hdr} - 64 ))
      [[ "$keep" -gt 0 ]] || keep=0
      { echo "$hdr"; echo "[... older content trimmed by loopwatch ...]"; tail -c "$keep" "$f"; } > "$f.tmp"
      mv "$f.tmp" "$f"
      TRIMMED_BYTES=$(( TRIMMED_BYTES + size - $(file_size "$f") ))
      excess=0
    fi
  done < <(sort -n "$RUN_DIR/bundle-index.tsv" 2>/dev/null)
  log "bundle over cap: trimmed ${TRIMMED_BYTES}B oldest-first to fit MAX_BUNDLE_KB=${MAX_BUNDLE_KB}"
}

bundle_bytes() {
  find "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" -type f -exec cat {} + 2>/dev/null | wc -c | tr -d ' '
}

# bytes of real content (headers excluded) — the activity bar compares against this
activity_bytes() {
  find "$RUN_DIR/bundle/transcripts" "$RUN_DIR/bundle/git" -type f -exec cat {} + 2>/dev/null \
    | { grep -v '^=== ' || true; } | wc -c | tr -d ' '
}

write_context() {
  jq -n \
    --arg date "$RUN_DATE" \
    --arg title "$(jq -r '.site_title // "Catalog"' "$MANIFEST")" \
    --argjson cats "$(jq '[.entries[].category] | unique' "$MANIFEST")" \
    --argjson slugs "$(jq '[.entries[-200:][].slug]' "$MANIFEST")" \
    '{run_date: $date, site_title: $title, existing_categories: $cats, recent_slugs: $slugs}' \
    > "$RUN_DIR/bundle/context.json"
}

collect_all() {
  cp "$WATERMARKS" "$RUN_DIR/new-watermarks.json"
  : > "$RUN_DIR/bundle-index.tsv"
  collect_globs "claude-code" ${CLAUDE_CODE_GLOBS[@]+"${CLAUDE_CODE_GLOBS[@]}"}
  collect_globs "cowork"      ${COWORK_GLOBS[@]+"${COWORK_GLOBS[@]}"}
  collect_github
  trim_bundle
  BUNDLE_BYTES="$(bundle_bytes)"
  write_context
}

has_activity() {
  [[ "$(activity_bytes)" -ge "$ACTIVITY_MIN_BYTES" ]]
}

list_sources() {
  local pat f size key old label decision
  echo "— transcript sources (status · total · new · source) —"
  for label in claude-code cowork; do
    local -a globs=()
    if [[ "$label" == "claude-code" ]]; then
      globs=(${CLAUDE_CODE_GLOBS[@]+"${CLAUDE_CODE_GLOBS[@]}"})
    else
      globs=(${COWORK_GLOBS[@]+"${COWORK_GLOBS[@]}"})
    fi
    for pat in ${globs[@]+"${globs[@]}"}; do
      echo "glob [$label]: $pat"
      local found=0
      while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        found=1
        decision="$(decide_source "$label" "$f")"
        [[ "$decision" == "ok" ]] && decision="include"
        size="$(file_size "$f")"
        key="$(hash_key "$f")"
        old="$(wm_get "$key")"
        printf '  %-22s %10sB %10sB  %s:%s\n' "$decision" "$size" "$(( size - ${old:-0} ))" \
          "$label" "$(basename "$(dirname "$f")")/$(basename "$f")"
      done < <(compgen -G "$pat" | LC_ALL=C sort || true)
      if [[ "$found" -eq 0 ]]; then echo "  (no matches)"; fi
    done
  done
}
