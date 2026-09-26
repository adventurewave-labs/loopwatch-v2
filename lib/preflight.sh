#!/usr/bin/env bash
# loopwatch lib — preflight (sourced; do not execute). R-5: fail closed on privacy.
#
# Runs before every publishing run and on `loopwatch-run.sh --preflight`.
# Prints PASS/WARN/FAIL lines; returns non-zero if anything FAILed.

PF_FAILS=0
pf_pass() { echo "PASS  $*"; }
pf_warn() { echo "WARN  $*"; }
pf_fail() { echo "FAIL  $*"; PF_FAILS=$((PF_FAILS + 1)); }

# Optional live check of Vercel Deployment Protection. Needs VERCEL_TOKEN in the
# environment (never stored by loopwatch) and VERCEL_PROJECT_ID (+ VERCEL_TEAM_ID) in the conf.
vercel_protection_check() {
  local url body
  url="https://api.vercel.com/v9/projects/${VERCEL_PROJECT_ID}"
  [[ -n "${VERCEL_TEAM_ID:-}" ]] && url="$url?teamId=$VERCEL_TEAM_ID"
  if ! body="$(curl -fsS --max-time 15 -H "Authorization: Bearer $VERCEL_TOKEN" "$url" 2>/dev/null)"; then
    pf_fail "could not read Vercel project $VERCEL_PROJECT_ID to confirm Deployment Protection (fail closed)"
    return
  fi
  # Vercel returns {"enabled": false} objects for protection that is off, and
  # "preview"-only protection leaves production public: both fail.
  local verdict
  verdict="$(jq -r '
    def on(x): x != null and ((x | has("enabled") | not) or x.enabled == true);
    def covers_prod(x): (x.deploymentType // "all") != "preview";
    if (on(.ssoProtection) and covers_prod(.ssoProtection)) then "ok vercel-auth:" + (.ssoProtection.deploymentType // "all")
    elif (on(.passwordProtection) and covers_prod(.passwordProtection)) then "ok password:" + (.passwordProtection.deploymentType // "all")
    elif (on(.ssoProtection) or on(.passwordProtection)) then "preview-only"
    else "none" end' <<< "$body" 2>/dev/null || echo none)"
  case "$verdict" in
    ok*)          pf_pass "Vercel project has Deployment Protection (${verdict#ok })" ;;
    preview-only) pf_fail "Vercel project $VERCEL_PROJECT_ID protects previews only — production would be public" ;;
    *)            pf_fail "Vercel project $VERCEL_PROJECT_ID has NO Deployment Protection — catalog would be public" ;;
  esac
}

preflight() {
  PF_FAILS=0
  local dep
  for dep in jq git "$CLAUDE_BIN"; do
    if command -v "$dep" >/dev/null 2>&1; then pf_pass "dependency: $(basename "$dep")"; else pf_fail "missing dependency: $dep"; fi
  done
  if [[ "${PREFLIGHT_NEEDS_GH:-false}" == "true" ]]; then
    if command -v "${GH_BIN:-gh}" >/dev/null 2>&1; then
      if "${GH_BIN:-gh}" auth status >/dev/null 2>&1; then pf_pass "gh authenticated"; else pf_fail "gh is not authenticated (gh auth login)"; fi
    else
      pf_fail "missing dependency: gh"
    fi
  fi

  # ── catalog visibility (R-5) ──
  if [[ "${ALLOW_PUBLIC:-false}" == "true" ]]; then
    pf_warn "ALLOW_PUBLIC=true — visibility checks bypassed; the catalog may be public"
  elif [[ "${SITE_VISIBILITY:-}" != "protected" ]]; then
    pf_fail "SITE_VISIBILITY is '${SITE_VISIBILITY:-unset}', must be 'protected' (or set ALLOW_PUBLIC=true to publish publicly)"
  else
    pf_pass "SITE_VISIBILITY=protected"
    if [[ -n "${VERCEL_PROJECT_ID:-}" && -n "${VERCEL_TOKEN:-}" ]]; then
      vercel_protection_check
    elif [[ -n "${VERCEL_PROJECT_ID:-}" ]]; then
      pf_warn "VERCEL_TOKEN not in environment — protection of $VERCEL_PROJECT_ID declared, not verified live"
    fi
  fi

  # ── redaction list (R-6) ──
  if [[ -z "${REDACT_LIST:-}" || ! -f "$REDACT_LIST" ]]; then
    pf_fail "redact.list not found at ${REDACT_LIST:-<unset>} (create it, even empty: touch it and chmod 600)"
  else
    local n dir
    if n="$(redact_list_check 2>/dev/null)"; then
      pf_pass "redact.list: $n rule(s) compile"
    else
      pf_fail "redact.list has a line that is not a valid regex: $(redact_list_check 2>/dev/null | head -3 | tr '\n' ' ')"
    fi
    dir="$(cd "$(dirname "$REDACT_LIST")" && pwd)"
    if git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
       && git -C "$dir" ls-files --error-unmatch "$(basename "$REDACT_LIST")" >/dev/null 2>&1; then
      pf_fail "redact.list is tracked by git in $dir — it must never be committed"
    fi
    if [[ -n "$(find "$REDACT_LIST" -perm -004 2>/dev/null)" ]]; then
      pf_warn "redact.list is world-readable (chmod 600 $REDACT_LIST)"
    fi
  fi

  # ── source allowlist (R-7) ──
  if [[ -z "${INCLUDE_PROJECTS[*]+x}" || "${#INCLUDE_PROJECTS[@]}" -eq 0 ]]; then
    pf_warn "INCLUDE_PROJECTS is empty — no transcripts will be collected (allowlist fails closed)"
  else
    pf_pass "INCLUDE_PROJECTS: ${#INCLUDE_PROJECTS[@]} pattern(s)"
  fi

  [[ "$PF_FAILS" -eq 0 ]]
}
