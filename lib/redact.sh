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
# The combined rules contain the client list, so they live outside the model's
# working directory ($STATE_DIR/private is 0700 and denied to headless Read/Grep/Glob).
build_rules() {
  mkdir -p "$STATE_DIR/private"
  RULES_JSON="$STATE_DIR/private/rules.json"
  ( umask 077; jq -nc --argjson a "$(builtin_rules_json)" --argjson b "$(redact_list_rules_json)" '$b + $a' > "$RULES_JSON" )
}

scrub_all() {
  [[ -n "${RULES_JSON:-}" && -f "$RULES_JSON" ]] || build_rules
  if [[ -n "${CANARY_ID:-}" ]]; then
    # Runtime self-test: every scrubbed stream carries a line of per-run canary secrets
    # (shaped to hit several built-in rules) through the SAME jq call as the real data.
    # canary_strip removes that line afterwards and records a leak if any canary survived.
    { canary_line; cat; } | jq -rR --slurpfile rules "$RULES_JSON" \
      'reduce $rules[0][] as $r (.; gsub($r.re; $r.repl; $r.flags))' | canary_strip
  else
    jq -rR --slurpfile rules "$RULES_JSON" \
      'reduce $rules[0][] as $r (.; gsub($r.re; $r.repl; $r.flags))'
  fi
}

# ── per-run canary (privacy pipeline self-test) ─────────────────────────
# CANARY_ID: "LWCANARY" + 8 random uppercase hex, fresh every run; it appears nowhere but in
# the canary line, so finding it anywhere after scrubbing is proof of a leak.
canary_init() {
  CANARY_ID="LWCANARY$(od -An -tx1 -N4 /dev/urandom | tr -d ' \n' | tr 'a-f' 'A-F')"
  : > "$RUN_DIR/.canary-streams"; rm -f "$RUN_DIR/.canary-leak"
}
canary_line() {
  printf '@@lw-canary@@ sk-%s0123456789 ghp_%sABCDEFGH AKIA%s token=%s1234 lw-%s@canary.invalid Bearer %sabcdefghijkl\n' \
    "$CANARY_ID" "$CANARY_ID" "$CANARY_ID" "$CANARY_ID" "$CANARY_ID" "$CANARY_ID"
}
canary_strip() {
  awk -v id="$CANARY_ID" -v leak="$RUN_DIR/.canary-leak" -v seen="$RUN_DIR/.canary-streams" '
    index($0, "@@lw-canary@@") == 1 { print "1" >> seen; if (index($0, id)) print $0 >> leak; next }
    { print }'
}
# canary_verify <expect-streams>: fails (1) with a reason when a canary survived scrubbing,
# when the id shows up anywhere in the run dir, or when bundle files exist that never went
# through scrub_all.
canary_verify() {
  local want="$1" got
  [[ -n "${CANARY_ID:-}" ]] || return 0
  if [[ -s "$RUN_DIR/.canary-leak" ]]; then echo "a canary secret survived scrubbing"; return 1; fi
  got="$(wc -l < "$RUN_DIR/.canary-streams" | tr -d ' ')"
  if [[ "$got" -lt "$want" ]]; then echo "only $got of $want bundle file(s) went through scrub_all"; return 1; fi
  if grep -rlF --exclude=.canary-leak "$CANARY_ID" "$RUN_DIR" >/dev/null 2>&1; then
    local hit; hit="$(grep -rlF --exclude=.canary-leak "$CANARY_ID" "$RUN_DIR" | head -1)"
    echo "canary id found in ${hit#"$RUN_DIR"/}"; return 1
  fi
  return 0
}

# input_scan <file>: the text about to be sent to a model must hold no rule hit at all
# (scrub replaced every match). A hit means data reached the model input without scrubbing.
input_scan() {
  local hits
  hits="$(postscan_hits "$1")"
  [[ -z "$hits" ]] || { printf '%s' "$hits" | tr '\n' ',' | sed 's/,$//'; return 1; }
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
      jq -r --arg s "$slug" '.pages[] | select(.slug == $s) | [.slug, .title, .summary, (.category // ""), ((.tags // []) | map(tostring) | join(" ")), (.source // "")] | map(tostring) | join("\n")' "$meta"
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
