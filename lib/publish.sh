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
      gsub("&#[xX]0*(?<h>[0-9a-fA-F]{1,6});?"; (.h | hexval | [.] | implode))
      | gsub("&#0*(?<d>[0-9]{1,7});?"; (.d | tonumber | [.] | implode))
      | gsub("&(?i:colon);"; ":") | gsub("&(?i:sol);"; "/") | gsub("&(?i:tab);"; "\t") | gsub("&(?i:newline);"; "\n")
      | gsub("&(?i:lpar);"; "(") | gsub("&(?i:rpar);"; ")") | gsub("&(?i:period);"; ".") | gsub("&(?i:bsol);"; "\\\\")
      | gsub("&(?i:quot);"; "\"") | gsub("&(?i:apos);"; "\u0027") | gsub("&(?i:lt);"; "<") | gsub("&(?i:gt);"; ">") | gsub("&(?i:amp);"; "&");
    # CSS: comments vanish and \HH escapes are characters, so u/**/rl( and \75rl( are url(
    def css: gsub("(?s)/\\*.*?\\*/"; "")
             | gsub("\\\\(?<h>[0-9a-fA-F]{1,6})[ \t\n\r\f]?"; (.h | hexval | [.] | implode))
             | gsub("\\\\(?<c>[^0-9a-fA-F\n])"; .c);
    # browsers drop ASCII tab/LF/CR anywhere in a URL and trim C0 controls + spaces at the ends
    def urlnorm: gsub("[\t\n\r]"; "") | sub("^[\u0000-\u0020]+"; "") | ascii_downcase;
    def bad_url: urlnorm | test("^(https?:|[/\\\\]{2}|javascript:|vbscript:|data:(?!image/(png|gif|jpeg|webp);))");
    # tokenise like a browser: attributes are split on the RAW tag, then each value is decoded
    def tagname: (capture("^</?(?<n>[A-Za-z][^\\s/>]*)").n // "") | ascii_downcase;
    def attrs: [ scan("[\\s/\"\u0027](?<n>[^\\s/>\"\u0027=]+)\\s*=\\s*(?<v>\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\\s>]+)")
                 | {n: (.[0] | ascii_downcase), v: (.[1] | sub("^[\"\u0027]"; "") | sub("[\"\u0027]$"; "") | decode)} ];
    . as $raw
    | ($raw | decode) as $dec
    # tags tokenised like the HTML attribute grammar: a quote only opens a value right after
    # "=", an unquoted value runs to whitespace or ">" (a stray quote is part of it), and a
    # ">" inside a quoted value does not end the tag. Atomic groups keep it linear.
    | [ $raw | scan("</?[A-Za-z](?>[^\\s/>]*)(?>[\\s/]*(?>[^\\s/>=]+)(?>\\s*=\\s*(?>\"[^\"]*\"|\u0027[^\u0027]*\u0027|[^\\s>]*))?)*[\\s/]*>|<[!?][^>]*>") | {name: tagname, attrs: attrs, dec: decode} ] as $tags
    # quote-UNaware view as well: a stray quote (`<p x=y" onmouseover=…>`) makes the quote-aware
    # scan miss the whole tag, while a browser treats that quote as part of an unquoted value
    | [ $raw | scan("<[A-Za-z][^<>]*>") | decode ] as $rawspans
    | if ($raw | test("<\\s*script"; "i")) then "inline or external <script>"
      elif ($tags | any(.name | test("^(script|iframe|object|embed|frame|frameset|applet|base|form|link|portal|svg|math|isindex|keygen|template|noscript|xmp|video|audio|source|marquee|details|dialog|input|button|select|textarea)$")))
        then "embedding/active element"
      elif ($tags | any(.name == "meta" and (.attrs | any(.n == "http-equiv")))) then "meta http-equiv"
      elif ($tags | any(.attrs | any(.n | startswith("on")))) or ($tags | any(.dec | test("[\\s/\"\u0027]on[a-z]+\\s*="; "i")))
            or ($rawspans | any(test("[\\s/\"\u0027]on[a-z]+\\s*="; "i")))
        then "on* event handler"
      elif ($tags | any(.attrs | any(.n == "srcset" or .n == "srcdoc" or .n == "popovertarget"))) then "srcset/srcdoc/popover attribute"
      elif ($tags | any(.attrs | any((.n | test("^(src|href|action|formaction|poster|data|background|xlink:href|ping|cite|longdesc|lowsrc|dynsrc|manifest|codebase|archive)$")) and (.v | bad_url))))
          or ($rawspans | any(test("[\\s/\"\u0027](src|href|action|formaction|poster|data|background|xlink:href|ping|cite|codebase|archive)\\s*=\\s*[\"\u0027]?\\s*(" + ([ "javascript:", "vbscript:", "https:", "http:" ] | map(split("") | join("[\\t\\n\\r]*")) | join("|")) + "|//)"; "i")))
        then "external or scriptable URL in an attribute"
      elif ((($dec | css) | test("url\\s*\\(|@import|expression\\s*\\(|image-set\\s*\\("; "i"))
            or ($tags | any(.attrs | any(.n == "style" and (.v | css | test("url\\s*\\(|expression\\s*\\(|image-set\\s*\\("; "i"))))))
        then "CSS url()/@import/expression"
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

# near_dups <meta.json>  ->  "<new-slug>\t<existing-slug>\t<score>" per near-duplicate page
#
# Exact-slug dedup misses the same topic written up twice under different slugs (a page
# re-derived from a later session, or two candidates on one decision). Each page's title +
# summary becomes a set of normalized word tokens (lowercased, stopwords and 1-2 char tokens
# dropped, a crude plural fold) and is compared by Jaccard similarity with every catalog entry
# and every page kept earlier in this run. Title overlap counts double, because titles are
# the densest statement of a page's topic. A score >= NEAR_DUP_THRESHOLD (default 0.55; 0 turns
# the guard off) marks the page as a duplicate. Deterministic, jq only, no dependencies.
near_dups() {
  local meta="$1" th="${NEAR_DUP_THRESHOLD:-0.55}"
  if ! [[ "$th" =~ ^(0|0?\.[0-9]+|1|1\.0+)$ ]]; then
    log "WARN: NEAR_DUP_THRESHOLD='$th' is not a number in [0,1]; using 0.55"; th=0.55
  fi
  awk -v t="$th" 'BEGIN { exit !(t > 0) }' || return 0
  jq -r --slurpfile m "$MANIFEST" --argjson th "$th" '
    def stop: ["the","and","for","with","from","into","that","this","via","when","why","how",
               "are","was","not","but","its","our","use","using","vs","per","one","two","all"];
    def toks: ascii_downcase | [scan("[a-z0-9]+")] | map(select(length > 2))
              | map(if (length > 3 and endswith("s") and (endswith("ss") | not)) then .[:-1] else . end)
              | map(select(. as $t | stop | index($t) | not)) | unique;
    def sig: {t: ((.title // "") | toks), s: ((.summary // "") | toks)};
    def jac($a; $b): if ($a + $b | length) == 0 then 0
                     else ([$a[] | select(. as $x | $b | index($x))] | length) / (($a + $b) | unique | length) end;
    # title tokens appear twice (as t:... and plain), so title overlap is weighted double
    def bag: [(.t[] | "t:" + .), (.t[]), (.s[])] | unique;
    def score($x; $y): jac($x | bag; $y | bag);
    reduce .pages[] as $p (
      {seen: [$m[0].entries[] | {slug, sig: sig}], out: []};
      ($p | sig) as $ps
      | ([.seen[] | {slug, sc: score($ps; .sig)}] | max_by(.sc)) as $best
      | if ($best != null and $best.sc >= $th and $best.slug != $p.slug)
        then .out += [[$p.slug, $best.slug, ($best.sc * 100 | round / 100 | tostring)]]
        else .seen += [{slug: $p.slug, sig: $ps}] end
    ) | .out[] | @tsv' "$meta"
}

# add_related <meta-final>: a static "Related" list in each newly installed page, just above
# its footer (plain links, no JS, so the page CSP stays script-free). Ranking is BM25 over the
# catalog (existing entries + this run's pages): the new page's title, tags and summary are
# the query; each document is its title and tags (weighted x2) plus its summary; k1=1.2,
# b=0.75. Up to RELATED_PAGES (3; 0 = off) links above RELATED_MIN_SCORE (1.5). Hrefs are built
# only from catalog paths shaped pages/<year>/<slug>.html and titles are HTML-escaped; the
# page is re-validated afterwards and keeps its old form if the list would trip anything.
# Older pages are immutable, so links point backwards (and across this run) only.
add_related() {
  local meta="$1" n="${RELATED_PAGES:-3}" min="${RELATED_MIN_SCORE:-1.5}" row slug path nav f
  [[ "$n" =~ ^[0-9]+$ ]] || { log "WARN: RELATED_PAGES='$n' is not a whole number; using 3"; n=3; }
  [[ "$n" -gt 0 ]] || return 0
  [[ "$min" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { log "WARN: RELATED_MIN_SCORE='$min' is not a number; using 1.5"; min=1.5; }
  RELATED_LINKS=0
  while IFS= read -r row; do
    slug="$(jq -r '.slug' <<< "$row")"; path="$(jq -r '.path' <<< "$row")"; nav="$(jq -r '.nav' <<< "$row")"
    f="$SITE_DIR/$path"
    [[ -f "$f" ]] || continue
    jq -Rrs --arg nav "$nav" 'sub("\n<footer>"; "\n" + $nav + "\n<footer>")' "$f" > "$f.rel"
    if [[ -n "$(html_problem "$f.rel")" ]] || ! grep -qF "$nav" "$f.rel"; then
      log "WARN: related list for $slug not added (failed re-validation)"; rm -f "$f.rel"; continue
    fi
    mv "$f.rel" "$f"
    RELATED_LINKS=$(( RELATED_LINKS + $(grep -o '<li><a href=' <<< "$nav" | wc -l | tr -d ' ') ))
  done < <(jq -r --slurpfile m "$MANIFEST" --argjson n "$n" --argjson min "$min" '
    def stop: ["the","and","for","with","from","into","that","this","via","when","why","how",
               "are","was","not","but","its","our","use","using","vs","per","one","two","all"];
    def toks: ascii_downcase | [scan("[a-z0-9]+")] | map(select(length > 2))
              | map(if (length > 3 and endswith("s") and (endswith("ss") | not)) then .[:-1] else . end)
              | map(select(. as $t | stop | index($t) | not));
    def terms: ((.title // "") | toks) as $t | (((.tags // []) | map(tostring) | join(" ")) | toks) as $g
               | $t + $t + $g + $g + ((.summary // "") | toks);
    def tf: reduce .[] as $w ({}; .[$w] += 1);
    def safe_path: type == "string" and test("^pages/[0-9]{4}/[a-z0-9][a-z0-9-]*\\.html$");
    ([$m[0].entries[], .pages[]] | map(select(.path | safe_path)) | map(. + {tf: (terms | tf), len: (terms | length)})) as $docs
    | ($docs | length) as $N
    | (if $N == 0 then 1 else ($docs | map(.len) | add) / $N end) as $avg
    | (reduce ($docs[] | .tf | keys[]) as $w ({}; .[$w] += 1)) as $df
    | .pages[] | . as $p | select(.path | safe_path)
    | (terms | unique) as $q
    | [ $docs[] | select(.slug != $p.slug) | . as $d
        | {title, path,
           score: ([ $q[] | . as $w | ($d.tf[$w] // 0) as $f | select($f > 0)
                     | (((($N - $df[$w] + 0.5) / ($df[$w] + 0.5)) + 1) | log)
                       * ($f * 2.2) / ($f + 1.2 * (0.25 + 0.75 * $d.len / $avg)) ] | add // 0)} ]
    | map(select(.score >= $min)) | sort_by(-.score) | .[:$n]
    | select(length > 0)
    | {slug: $p.slug, path: $p.path,
       nav: ("<nav><h2>Related</h2><ul>"
         + (map("<li><a href=\"../" + (.path | ltrimstr("pages/") | @html) + "\">" + (.title | tostring | @html) + "</a></li>") | join(""))
         + "</ul></nav>")} | @json' "$meta")
  [[ "$RELATED_LINKS" -eq 0 ]] || log "related: $RELATED_LINKS link(s) added to new pages"
}

publish_run() {
  local meta="$1"
  local year installed=0 skipped=0
  year="$(date +%Y)"

  # dedup against manifest + install pages: exact slug first, then near-duplicates
  near_dups "$meta" > "$RUN_DIR/near-dups.tsv"
  : > "$RUN_DIR/installed-slugs.txt"
  local slug file nd
  while IFS=$'\t' read -r slug file; do
    [[ -n "$slug" ]] || continue
    if jq -e --arg s "$slug" '.entries | any(.slug == $s)' "$MANIFEST" >/dev/null; then
      log "dedup: slug already in catalog, skipping: $slug"
      skipped=$((skipped + 1))
      continue
    fi
    nd="$(awk -F'\t' -v s="$slug" '$1 == s { print $2 " (similarity " $3 ")"; exit }' "$RUN_DIR/near-dups.tsv")"
    if [[ -n "$nd" ]]; then
      # keep the page recoverable: the run dir is wiped next run and watermarks advance
      mkdir -p "$STATE_DIR/private/near-dups/$RUN_TS"
      cp "$RUN_DIR/$file" "$STATE_DIR/private/near-dups/$RUN_TS/$slug.html" 2>/dev/null || true
      log "dedup: near-duplicate of $nd, skipping: $slug (kept at $STATE_DIR/private/near-dups/$RUN_TS/$slug.html)"
      NEAR_DUP_DROPS=$((${NEAR_DUP_DROPS:-0} + 1))
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
  add_related "$RUN_DIR/meta-final.json"

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
