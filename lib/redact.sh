#!/usr/bin/env bash
# loopwatch lib — redaction (sourced; do not execute). R-6 + bug 5.
#
# One rule set drives both directions:
#   scrub_all  — rewrites every line of collected text BEFORE the model sees it
#   postscan   — re-scans generated pages, the digest and run-meta AFTER extraction;
#                any hit drops the page (fail closed) and is counted in the ledger.
#
# Rules are Oniguruma regexes applied by jq, case-insensitive for redact.list terms.
# redact.list format (gitignored, lives in ~/.config/loopwatch/redact.list):
#   # comment
#   Globex                         -> [REDACTED:entity]
#   Initech( Corp)?=>ACME-2        -> ACME-2
# Each line is a regex; escape . ( ) [ ] etc. when you mean them literally.

# Built-in secret patterns: [kind, regex, flags]
builtin_rules_json() {
  jq -nc '[
    ["key",        "sk-[A-Za-z0-9_-]{16,}", ""],
    ["stripe",     "(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{16,}", ""],
    ["github",     "gh[pousr]_[A-Za-z0-9]{20,}", ""],
    ["github",     "github_pat_[A-Za-z0-9_]{20,}", ""],
    ["aws",        "AKIA[0-9A-Z]{16}", ""],
    ["slack",      "xox[baprs]-[A-Za-z0-9-]{10,}", ""],
    ["google",     "AIza[0-9A-Za-z_-]{35}", ""],
    ["jwt",        "eyJ[A-Za-z0-9_-]{15,}\\.[A-Za-z0-9_-]{15,}\\.[A-Za-z0-9_-]{10,}", ""],
    ["pem",        "-----BEGIN [A-Z ]*PRIVATE KEY-----", ""],
    ["bearer",     "bearer\\s+[A-Za-z0-9._~+/=-]{20,}", "i"],
    ["conn-creds", "[A-Za-z][A-Za-z0-9+.-]*://[^\\s:/@]+:[^\\s@/]+@", ""],
    ["assignment", "(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key|private[_-]?key)[\"'"'"']?\\s*[:=]\\s*[\"'"'"']?(?=[^\\s\"'"'"',;]*[0-9])[^\\s\"'"'"',;]{8,}", "i"],
    ["email",      "[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\\.[A-Za-z0-9-]+)*\\.[A-Za-z]{2,}", ""]
  ] | map({kind: .[0], re: .[1], flags: .[2],
            repl: ("[REDACTED:" + .[0] + "]" + (if .[0] == "conn-creds" then "@" else "" end))})'
}

# redact.list -> [{kind:"redact.list:<line>", re, flags:"i", repl}]
redact_list_rules_json() {
  local list="${REDACT_LIST:-}"
  if [[ -z "$list" || ! -f "$list" ]]; then echo '[]'; return; fi
  jq -Rsc '
    split("\n") | to_entries
    | map(.value |= (sub("\r$"; "")) | select(.value | test("^\\s*(#|$)") | not))
    | map(.key as $n | (.value | split("=>")) as $p
          | { kind: ("redact.list:" + (($n + 1) | tostring)),
              re:   ($p[0] | sub("^\\s+"; "") | sub("\\s+$"; "")),
              repl: (if ($p | length) > 1 then ($p[1:] | join("=>") | sub("^\\s+"; "") | sub("\\s+$"; "")) else "[REDACTED:entity]" end),
              flags: "i" })
    | map(select(.re != ""))' "$list"
}

# Materialize the combined rule set once per run.
build_rules() {
  RULES_JSON="$RUN_DIR/.rules.json"
  jq -nc --argjson a "$(builtin_rules_json)" --argjson b "$(redact_list_rules_json)" '$b + $a' > "$RULES_JSON"
}

scrub_all() {
  [[ -n "${RULES_JSON:-}" && -f "$RULES_JSON" ]] || build_rules
  jq -rR --slurpfile rules "$RULES_JSON" \
    'reduce $rules[0][] as $r (.; gsub($r.re; $r.repl; $r.flags))'
}

# postscan_text <file>: prints the kinds of the rules that match (one per line)
postscan_hits() {
  jq -rRs --slurpfile rules "$RULES_JSON" \
    '. as $t | $rules[0][] | select(. as $r | $t | test($r.re; $r.flags)) | .kind' "$1" 2>/dev/null | sort -u
}

# postscan <meta>: drop any page whose HTML, title, summary, tags or slug hits a rule;
# withhold digest text that hits. Rewrites <meta> in place. Sets POSTSCAN_DROPS.
postscan() {
  local meta="$1" slug file tmp hits kinds
  [[ -n "${RULES_JSON:-}" && -f "$RULES_JSON" ]] || build_rules
  tmp="$RUN_DIR/.postscan.tmp"
  : > "$RUN_DIR/.postscan-drop.txt"
  while IFS=$'\t' read -r slug file; do
    [[ -n "$slug" ]] || continue
    # scan the page HTML plus its catalog-facing metadata together
    { cat "$RUN_DIR/$file" 2>/dev/null
      jq -r --arg s "$slug" '.pages[] | select(.slug == $s) | [.slug, .title, .summary, ((.tags // []) | join(" ")), (.source // "")] | join("\n")' "$meta"
    } > "$tmp"
    hits="$(postscan_hits "$tmp")"
    if [[ -n "$hits" ]]; then
      kinds="$(printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//')"
      log "postscan: dropped a page (rules: $kinds)"
      echo "$slug" >> "$RUN_DIR/.postscan-drop.txt"
      rm -f "$RUN_DIR/$file"
      POSTSCAN_DROPS=$(( ${POSTSCAN_DROPS:-0} + 1 ))
    fi
  done < <(jq -r '.pages[] | [.slug, .file] | @tsv' "$meta")

  # digest text: withhold the summary / drop highlights that hit
  jq -r '.digest_summary' "$meta" > "$tmp"
  if [[ -n "$(postscan_hits "$tmp")" ]]; then
    log "postscan: digest summary withheld (redaction hit)"
    POSTSCAN_DROPS=$(( ${POSTSCAN_DROPS:-0} + 1 ))
    jq '.digest_summary = "(digest summary withheld by loopwatch: redaction rule hit)"' "$meta" > "$tmp" && mv "$tmp" "$meta"
  fi
  local keep_hl='[]' h n=0
  while IFS= read -r h; do
    printf '%s' "$h" > "$tmp"
    if [[ -n "$(postscan_hits "$tmp")" ]]; then
      n=$((n + 1))
    else
      keep_hl="$(jq -c --arg h "$h" '. + [$h]' <<< "$keep_hl")"
    fi
  done < <(jq -r '(.highlights // [])[]' "$meta")
  if [[ "$n" -gt 0 ]]; then
    log "postscan: dropped $n digest highlight(s)"
    POSTSCAN_DROPS=$(( ${POSTSCAN_DROPS:-0} + n ))
  fi

  jq --argjson hl "$keep_hl" --rawfile drop "$RUN_DIR/.postscan-drop.txt" '
    ($drop | split("\n") | map(select(. != ""))) as $d
    | .highlights = $hl
    | .pages = (.pages | map(select(.slug as $s | $d | index($s) | not)))' "$meta" > "$tmp" && mv "$tmp" "$meta"
  rm -f "$tmp"
}

# validate every redact.list line compiles (used by preflight)
redact_list_check() {
  local rules bad
  rules="$(redact_list_rules_json)" || return 1
  bad="$(jq -r '.[] | . as $r | (try ("" | test($r.re; "i") | "ok") catch ("BAD " + $r.kind)) | select(startswith("BAD"))' <<< "$rules")"
  [[ -z "$bad" ]] || { echo "$bad"; return 1; }
  jq 'length' <<< "$rules"
}
