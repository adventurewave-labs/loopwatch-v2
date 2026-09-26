#!/usr/bin/env bash
# loopwatch lib — validation, digest, manifest merge (sourced by loopwatch-run.sh; do not execute)

validate_meta() {
  local meta="$1"
  jq -e 'type == "object"
         and (.pages | type == "array")
         and (.digest_summary | type == "string")' "$meta" >/dev/null \
    || die "run-meta.json: bad top-level shape"

  # per-page firewall: any page that fails is dropped (fail closed), the run continues
  local slug file reason tmp
  tmp="$RUN_DIR/.validate.tmp"
  : > "$RUN_DIR/.invalid.txt"
  while IFS= read -r row; do
    slug="$(jq -r 'if type == "object" then (.slug // "" | tostring) else "" end' <<< "$row")"
    file="$(jq -r 'if type == "object" then (.file // "" | tostring) else "" end' <<< "$row")"
    reason="$(page_problem "$row")"
    if [[ -n "$reason" ]]; then
      log "validator: dropped page ${slug:-<no slug>}: $reason"
      printf '%s\n' "$slug" >> "$RUN_DIR/.invalid.txt"
      if [[ "$file" =~ ^pages/[a-z0-9-]+\.html$ ]]; then rm -f "$RUN_DIR/$file"; fi
      VALIDATOR_DROPS=$(( ${VALIDATOR_DROPS:-0} + 1 ))
    fi
  done < <(jq -c '.pages[]' "$meta")
  jq --rawfile bad "$RUN_DIR/.invalid.txt" '
    ($bad | split("\n") | map(select(. != ""))) as $b
    | .pages = ([.pages[] | select(type == "object" and ((.slug // "") | type == "string"))
                           | select((.slug // "") as $s | $b | index($s) | not)]
                | unique_by(.slug))' "$meta" > "$tmp" && mv "$tmp" "$meta"
}

# page_problem <page-json>: prints why a page must be dropped, or nothing
page_problem() {
  local row="$1" file
  jq -e 'type == "object" and
      (.slug     | type == "string" and test("^[a-z0-9][a-z0-9-]{2,79}$")) and
      (.title    | type == "string" and length > 0 and length < 200) and
      (.category | type == "string" and test("^[a-z0-9-]+(/[a-z0-9-]+)?$")) and
      (.summary  | type == "string" and length > 0) and
      ((.tags // []) | type == "array") and
      (.file     | type == "string" and test("^pages/[a-z0-9][a-z0-9-]{2,79}\\.html$"))' <<< "$row" >/dev/null 2>&1 \
    || { echo "schema"; return; }
  file="$RUN_DIR/$(jq -r '.file' <<< "$row")"
  [[ -f "$file" ]] || { echo "missing file"; return; }
  head -c 512 "$file" | grep -qi '<!doctype html\|<html' || { echo "not an html doc"; return; }
  html_problem "$file"
}

# html_problem <file>: the markup firewall (R-11). Works on real tags only (a quoted '>'
# inside an attribute does not end the tag), decodes character references and strips
# the tab/newline/NUL characters browsers ignore inside URLs before matching, so
# entity-encoded or whitespace-split schemes are caught too.
html_problem() {
  jq -Rrs '
    def hexval: ascii_downcase | explode | reduce .[] as $c (0; . * 16 + (if $c >= 97 then $c - 87 else $c - 48 end));
    def decode:
      gsub("&#[xX](?<h>[0-9a-fA-F]{1,6});?"; (.h | hexval | [.] | implode))
      | gsub("&#(?<d>[0-9]{1,7});?"; (.d | tonumber | [.] | implode))
      | gsub("&(?i:colon);"; ":") | gsub("&(?i:sol);"; "/") | gsub("&(?i:tab);"; "\t") | gsub("&(?i:newline);"; "\n")
      | gsub("&(?i:lpar);"; "(") | gsub("&(?i:rpar);"; ")") | gsub("&(?i:period);"; ".") | gsub("&(?i:bsol);"; "\\\\")
      | gsub("&(?i:quot);"; "\"") | gsub("&(?i:apos);"; "\u0027") | gsub("&(?i:lt);"; "<") | gsub("&(?i:gt);"; ">") | gsub("&(?i:amp);"; "&");
    def squash: gsub("[\t\n\r]"; "");
    . as $raw
    | ($raw | decode) as $dec
    | [ $raw | scan("<[A-Za-z!/?](?:\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\"\u0027>])*>") ] as $tags
    | ($tags | map(decode | squash)) as $t
    | if ($raw | test("<\\s*script"; "i")) then "inline or external <script>"
      elif ($t | any(test("^<(iframe|object|embed|frame|frameset|applet|base|form|link|portal|svg|math)[\\s/>]"; "i"))) then "embedding/linking element"
      elif ($t | any(test("^<meta[^>]*http-equiv"; "i"))) then "meta http-equiv"
      elif ($t | any(test("[\\s/\"\u0027]on[a-z]+\\s*="; "i"))) then "on* event handler"
      elif ($t | any(test("[\\s/\"\u0027](src|href|srcset|action|formaction|poster|data|background|xlink:href|ping|cite|longdesc|lowsrc|dynsrc|manifest|codebase|archive)\\s*=\\s*[\"\u0027]?\\s*(https?:|//|\\\\\\\\|javascript:|vbscript:|data:(?!image/(png|gif|jpeg|webp);))"; "i")))
        then "external or scriptable URL in an attribute"
      elif ($dec | test("url\\s*\\(|@import|expression\\s*\\("; "i")) then "CSS url()/@import/expression"
      else empty end' "$1"
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

  # dedup against manifest + install pages
  : > "$RUN_DIR/installed-slugs.txt"
  local slug file
  while IFS=$'\t' read -r slug file; do
    [[ -n "$slug" ]] || continue
    if jq -e --arg s "$slug" '.entries | any(.slug == $s)' "$MANIFEST" >/dev/null; then
      log "dedup: slug already in catalog, skipping: $slug"
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$SITE_DIR/pages/$year"
    cp "$RUN_DIR/$file" "$SITE_DIR/pages/$year/$slug.html"
    echo "$slug" >> "$RUN_DIR/installed-slugs.txt"
    installed=$((installed + 1))
  done < <(jq -r '.pages[] | [.slug, .file] | @tsv' "$meta")

  # meta-final: only installed pages, with catalog path + date stamped
  local keep_json
  keep_json="$(jq -R . < "$RUN_DIR/installed-slugs.txt" | jq -s .)"
  jq --argjson keep "$keep_json" --arg year "$year" --arg date "$RUN_DATE" '
    .pages = (.pages
      | map(select(.slug as $s | $keep | index($s)))
      | map(. + {path: ("pages/" + $year + "/" + .slug + ".html"), date: $date}))
  ' "$meta" > "$RUN_DIR/meta-final.json"

  # digest (unique name if a same-day run already published one)
  local digest_name="$RUN_DATE"
  if [[ -f "$SITE_DIR/digests/$digest_name.html" ]]; then
    digest_name="${RUN_DATE}-$(date +%H%M)"
  fi
  local digest_rel="digests/$digest_name.html"
  write_digest "$RUN_DIR/meta-final.json" "$SITE_DIR/$digest_rel"

  # manifest merge (atomic: validate the new doc before moving it into place)
  local now
  now="$(date -u +%FT%TZ)"
  jq --slurpfile m "$RUN_DIR/meta-final.json" \
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
  ' "$MANIFEST" > "$RUN_DIR/manifest.new"
  jq -e . "$RUN_DIR/manifest.new" >/dev/null || die "manifest merge produced invalid JSON"
  cp "$RUN_DIR/manifest.new" "$MANIFEST"

  # commit on the run branch, then push it and open/update the PR (lib/catalog.sh).
  # Watermarks are local state (bug 7); the caller advances them only after this returns.
  catalog_git add -A site
  INSTALLED_PAGES="$installed"
  if catalog_git diff --cached --quiet; then
    log "nothing to commit"
    return 0
  fi
  catalog_git commit -q -m "loopwatch: $RUN_DATE — ${installed} page(s), digest"
  log "committed: $installed installed, $skipped deduped, digest $digest_rel"
  push_and_pr
}
