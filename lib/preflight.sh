#!/usr/bin/env bash
# loopwatch lib — preflight (sourced; do not execute). R-5: fail closed on privacy.
#
# Runs before every publishing run and on `loopwatch-run.sh --preflight`.
# Prints PASS/WARN/FAIL lines; returns non-zero if anything FAILed.

PF_FAILS=0
pf_pass() { echo "PASS  $*"; }
pf_warn() { echo "WARN  $*"; }
pf_fail() { echo "FAIL  $*"; PF_FAILS=$((PF_FAILS + 1)); }

# Live probe (host-agnostic): an unauthenticated GET of $SITE_URL/manifest.json must be
# refused (401/403, or 503 from the catalog server while its credentials are unset).
# A 200 means the catalog is public; no answer means we cannot tell. Both fail closed.
site_protection_check() {
  local url code
  url="${SITE_URL%/}/manifest.json"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "$url" 2>/dev/null || true)"
  case "$code" in
    401|403) pf_pass "live check: $url refuses anonymous requests ($code)" ;;
    503)     pf_warn "live check: $url is locked (503): the catalog server has no credentials yet, so it serves nothing" ;;
    200)     pf_fail "live check: $url is PUBLIC (200 without credentials)" ;;
    *)       pf_fail "live check: $url did not answer as protected (HTTP ${code:-none}), fail closed" ;;
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
    if [[ -n "${SITE_URL:-}" ]]; then
      site_protection_check
    else
      pf_warn "SITE_URL not set: protection is declared, not verified live"
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
