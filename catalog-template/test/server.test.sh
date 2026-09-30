#!/usr/bin/env bash
# Smoke test for server.js: fails closed, enforces Basic Auth, blocks traversal, sets headers.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=18765
pids=()
cleanup() { for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; }
trap cleanup EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
wait_up() { for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$1/healthz" >/dev/null && return 0; sleep 0.1; done; fail "server on $1 did not start"; }

# 1. no credentials configured -> locked
PORT=$PORT node server.js >/dev/null & pids+=($!)
wait_up $PORT
[[ "$(code http://127.0.0.1:$PORT/healthz)" == 200 ]] || fail "healthz"
[[ "$(code http://127.0.0.1:$PORT/)" == 503 ]] || fail "unconfigured server must fail closed (503)"
[[ "$(code -u a:b http://127.0.0.1:$PORT/manifest.json)" == 503 ]] || fail "unconfigured server must not serve even with auth"
echo "  ok: fails closed without credentials"

# 2. credentials configured
P2=$((PORT + 1))
PORT=$P2 CATALOG_USER=marcus CATALOG_PASSWORD='s3cret test' node server.js >/dev/null & pids+=($!)
wait_up $P2
[[ "$(code http://127.0.0.1:$P2/)" == 401 ]] || fail "no auth -> 401"
[[ "$(code -u marcus:wrong http://127.0.0.1:$P2/)" == 401 ]] || fail "wrong password -> 401"
[[ "$(code -u 'marcus:s3cret test' http://127.0.0.1:$P2/)" == 200 ]] || fail "right password -> 200"
[[ "$(code -u 'marcus:s3cret test' http://127.0.0.1:$P2/manifest.json)" == 200 ]] || fail "manifest"
[[ "$(code -u 'marcus:s3cret test' --path-as-is 'http://127.0.0.1:'$P2'/../server.js')" == 404 ]] || fail "traversal must 404"
[[ "$(code -u 'marcus:s3cret test' 'http://127.0.0.1:'$P2'/%2e%2e/server.js')" == 404 ]] || fail "encoded traversal must 404"
hdr="$(curl -s -D - -o /dev/null -u 'marcus:s3cret test' "http://127.0.0.1:$P2/")"
grep -qi "^content-security-policy: default-src 'none'; script-src 'self'" <<< "$hdr" || fail "CSP header"
grep -qi '^x-robots-tag: noindex' <<< "$hdr" || fail "noindex header"
echo "  ok: 401 without/with wrong creds, 200 with creds, traversal blocked, CSP + noindex set"
echo "PASS — catalog server"
