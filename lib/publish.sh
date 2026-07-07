#!/usr/bin/env bash
# loopwatch lib — validation + publishing (sourced by loopwatch-run.sh; do not execute)

validate_meta() {
  local meta="$1"
  jq -e 'type == "object"
         and (.pages | type == "array")
         and (.digest_summary | type == "string")' "$meta" >/dev/null \
    || die "run-meta.json: bad top-level shape"

  jq -e '
    .pages | all(
      (.slug     | type == "string" and test("^[a-z0-9][a-z0-9-]{2,79}$")) and
      (.title    | type == "string" and length > 0) and
      (.category | type == "string" and test("^[a-z0-9-]+(/[a-z0-9-]+)?$")) and
      (.summary  | type == "string" and length > 0) and
      (.file     | type == "string" and startswith("pages/"))
    )' "$meta" >/dev/null || die "run-meta.json: a page entry failed the schema"

  local f
  while IFS= read -r f; do
    [[ -f "$STAGING/$f" ]] || die "meta references missing file: $f"
    head -c 512 "$STAGING/$f" | grep -qi '<!doctype html\|<html' || die "not an html doc: $f"
    if grep -qiE 'src="https?://|href="https?://[^"]*\.(css|js)' "$STAGING/$f"; then
      die "external resource in $f — pages must be fully self-contained"
    fi
  done < <(jq -r '.pages[].file' "$meta")
}

write_digest() {
  local meta_final="$1" out_file="$2"
  local summary_html items_html hl_html n
  summary_html="$(jq -r '.digest_summary | @html' "$meta_final")"
  hl_html="$(jq -r '(.highlights // [])[] | "<li>" + @html + "</li>"' "$meta_final")"
  items_html="$(jq -r '.pages[]
    | "<li><a href=\"../" + .path + "\">" + (.title | @html) + "</a>"
      + "<span class=\"cat\">" + (.category | @html) + "</span>"
      + "<p>" + (.summary | @html) + "</p></li>"' "$meta_final")"
  n="$(jq '.pages | length' "$meta_final")"
  if [[ "$n" -eq 0 ]]; then
    items_html="<li class=\"none\">No pages published — activity stayed below the reference bar today.</li>"
  fi

  mkdir -p "$(dirname "$out_file")"
  cat > "$out_file" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Digest — $RUN_DATE</title>
<style>
  :root { color-scheme: dark; }
  body { margin:0; background:#0f1115; color:#d7dae0; font:16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
  main { max-width:780px; margin:0 auto; padding:48px 24px; }
  h1 { font-size:1.5rem; margin:0 0 4px; }
  .back { font-size:.85rem; }
  a { color:#6ea8fe; text-decoration:none; }
  a:hover { text-decoration:underline; }
  .summary { background:#161a22; border:1px solid #232838; border-radius:8px; padding:16px 20px; margin:24px 0; }
  h2 { font-size:1.05rem; color:#8b93a7; text-transform:uppercase; letter-spacing:.05em; margin-top:36px; }
  ul { list-style:none; padding:0; }
  li { padding:10px 0; border-bottom:1px solid #1b2030; }
  li .cat { margin-left:10px; font-size:.75rem; color:#8b93a7; background:#161a22; border:1px solid #232838; border-radius:99px; padding:2px 10px; }
  li p { margin:4px 0 0; color:#a7adbd; font-size:.9rem; }
  .hl li { color:#a7adbd; font-size:.92rem; padding:4px 0; border:none; }
  .hl li::before { content:"— "; color:#6ea8fe; }
  .none { color:#8b93a7; }
</style>
</head>
<body><main>
<div class="back"><a href="../index.html">&larr; catalog</a></div>
<h1>Digest — $RUN_DATE</h1>
<div class="summary">$summary_html</div>
<h2>Published</h2>
<ul>
$items_html
</ul>
<h2>Highlights</h2>
<ul class="hl">
$hl_html
</ul>
</main></body>
</html>
EOF
}

publish_run() {
  local meta="$1"
  local year installed=0 skipped=0
  year="$(date +%Y)"

  if [[ "$PULL" == "true" ]]; then
    git -C "$REPO_DIR" pull --rebase --autostash 2>/dev/null \
      || log "WARN: git pull failed (offline / no upstream?) — continuing with local state"
  fi

  # dedup against manifest + install pages
  : > "$STAGING/installed-slugs.txt"
  local slug file
  while IFS=$'\t' read -r slug file; do
    [[ -n "$slug" ]] || continue
    if jq -e --arg s "$slug" '.entries | any(.slug == $s)' "$MANIFEST" >/dev/null; then
      log "dedup: slug already in catalog, skipping: $slug"
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$SITE_DIR/pages/$year"
    cp "$STAGING/$file" "$SITE_DIR/pages/$year/$slug.html"
    echo "$slug" >> "$STAGING/installed-slugs.txt"
    installed=$((installed + 1))
  done < <(jq -r '.pages[] | [.slug, .file] | @tsv' "$meta")

  # meta-final: only installed pages, with catalog path + date stamped
  local keep_json
  keep_json="$(jq -R . < "$STAGING/installed-slugs.txt" | jq -s .)"
  jq --argjson keep "$keep_json" --arg year "$year" --arg date "$RUN_DATE" '
    .pages = (.pages
      | map(select(.slug as $s | $keep | index($s)))
      | map(. + {path: ("pages/" + $year + "/" + .slug + ".html"), date: $date}))
  ' "$meta" > "$STAGING/meta-final.json"

  # digest (unique name if a same-day run already published one)
  local digest_name="$RUN_DATE"
  if [[ -f "$SITE_DIR/digests/$digest_name.html" ]]; then
    digest_name="${RUN_DATE}-$(date +%H%M)"
  fi
  local digest_rel="digests/$digest_name.html"
  write_digest "$STAGING/meta-final.json" "$SITE_DIR/$digest_rel"

  # manifest merge (atomic: validate the new doc before moving it into place)
  local now
  now="$(date -u +%FT%TZ)"
  jq --slurpfile m "$STAGING/meta-final.json" \
     --arg now "$now" --arg dpath "$digest_rel" --arg date "$RUN_DATE" '
    .updated = $now
    | .entries += ($m[0].pages | map({
        slug, title, category,
        tags: (.tags // []),
        date, path, summary,
        source: (.source // "")
      }))
    | .digests = ([{
        date: $date, path: $dpath,
        summary: $m[0].digest_summary,
        pages: ($m[0].pages | length)
      }] + .digests)
  ' "$MANIFEST" > "$STAGING/manifest.new"
  jq -e . "$STAGING/manifest.new" >/dev/null || die "manifest merge produced invalid JSON"
  cp "$STAGING/manifest.new" "$MANIFEST"

  # persist watermarks, then commit everything atomically
  cp "$STAGING/new-watermarks.json" "$WATERMARKS"

  git -C "$REPO_DIR" add -A "$SITE_DIR" 2>/dev/null || true
  git -C "$REPO_DIR" add -A "$WATERMARKS" 2>/dev/null || true
  if git -C "$REPO_DIR" diff --cached --quiet; then
    log "nothing to commit"
    return 0
  fi
  git -C "$REPO_DIR" commit -q -m "loopwatch: $RUN_DATE — ${installed} page(s), digest"
  if [[ "$PUSH" == "true" ]]; then
    git -C "$REPO_DIR" push -q 2>/dev/null \
      || log "WARN: push failed — commit is local; next run will retry the push"
  fi
  log "published: $installed installed, $skipped deduped, digest $digest_rel"
}
