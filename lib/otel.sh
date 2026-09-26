#!/usr/bin/env bash
# loopwatch lib — OpenTelemetry export (sourced; do not execute).
#
# otel_export <ledger-row-json>
#   Turns one run into an OTLP/JSON trace that follows the OpenTelemetry GenAI semantic
#   conventions, so any OTel backend (or Turbo Rig) can chart loopwatch next to everything
#   else without a bespoke parser:
#     root span   "loopwatch run"            kind INTERNAL, run outcome as loopwatch.* attributes
#     child span  "chat <model>" per stage   kind CLIENT, gen_ai.operation.name=chat,
#                 gen_ai.provider.name=anthropic, gen_ai.request.model, gen_ai.usage.*_tokens
#   Spans carry counts, models, costs and outcomes only: never prompt, bundle or page text.
#
#   Set these in loopwatch.conf. Ambient OTEL_* variables from the shell are ignored, so a
#   collector configured for other tools never receives loopwatch traces by accident.
#   OTEL_EXPORT_DIR                write <dir>/<run_id>.otlp.json (one ExportTraceServiceRequest)
#   OTEL_EXPORTER_OTLP_ENDPOINT    also POST it to <endpoint>/v1/traces (standard OTel env var;
#   OTEL_EXPORTER_OTLP_HEADERS     "k=v,k2=v2" headers, e.g. an API key; 5s timeout)
#   Both unset = no export. Export problems are logged and never fail the run.

otel_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

otel_payload() {  # otel_payload <ledger-row-json> <usage-file>  -> OTLP/JSON on stdout
  local row="$1" usage="$2" version
  version="$(cat "$ROOT_DIR/VERSION" 2>/dev/null || echo unknown)"
  local -a sids=() ; local i n
  n="$(grep -c . "$usage" 2>/dev/null || true)"; n="${n:-0}"
  for (( i = 0; i < n; i++ )); do sids+=("$(otel_hex 8)"); done
  jq -sc \
    --argjson row "$row" \
    --arg trace "$(otel_hex 16)" \
    --arg root "$(otel_hex 8)" \
    --arg sids "${sids[*]:-}" \
    --arg version "$version" \
    --argjson start "${RUN_START:-0}" \
    --argjson end "$(now_epoch)" '
    def ns: . * 1000000000 | floor | tostring;
    def attr($k; $v):
      {key: $k, value: (
        if   ($v | type) == "boolean" then {boolValue: $v}
        elif ($v | type) == "number" and ($v | floor) == $v then {intValue: ($v | tostring)}
        elif ($v | type) == "number" then {doubleValue: $v}
        else {stringValue: ($v | tostring)} end)};
    def attrs: to_entries | map(select(.value != null) | attr(.key; .value));
    ($sids | split(" ")) as $ids
    | . as $stages
    | {resourceSpans: [{
        resource: {attributes: ({"service.name": "loopwatch", "service.version": $version,
                                 "deployment.environment.name": ($row.target // "manual")} | attrs)},
        scopeSpans: [{
          scope: {name: "loopwatch", version: $version},
          spans: (
            [{traceId: $trace, spanId: $root, name: "loopwatch run", kind: 1,
              startTimeUnixNano: ($start | ns), endTimeUnixNano: ([$end, $start] | max | ns),
              status: (if $row.status == "failed" then {code: 2, message: ($row.skipped_reason // "failed")} else {code: 1} end),
              attributes: ({
                "loopwatch.run_id": $row.run_id, "loopwatch.status": $row.status,
                "loopwatch.prompt_version": $row.prompt_version,
                "loopwatch.dry_run": $row.dry_run, "loopwatch.pages": $row.pages,
                "loopwatch.skipped_reason": $row.skipped_reason,
                "loopwatch.stage_b_skipped": $row.stage_b_skipped,
                "loopwatch.cost_usd": $row.cost_usd,
                "loopwatch.bundle_bytes": $row.bundle_bytes, "loopwatch.trimmed_bytes": $row.trimmed_bytes,
                "loopwatch.validator_drops": $row.validator_drops, "loopwatch.postscan_drops": $row.postscan_drops
              } | attrs)}]
            + [ $stages | to_entries[] | .key as $i | .value as $s
                | (($s.start_s // $start)) as $t0
                | {traceId: $trace, spanId: $ids[$i], parentSpanId: $root,
                   name: ("chat " + $s.model), kind: 3,
                   startTimeUnixNano: ($t0 | ns),
                   endTimeUnixNano: ($t0 + (($s.duration_ms // 0) / 1000) | ns),
                   status: (if $s.is_error then {code: 2, message: ($s.subtype // "error")} else {code: 1} end),
                   attributes: ({
                     "gen_ai.operation.name": "chat",
                     "gen_ai.provider.name": "anthropic",
                     "gen_ai.system": "anthropic",
                     "gen_ai.request.model": $s.model,
                     "gen_ai.output.type": "json",
                     "gen_ai.usage.input_tokens": (($s.in // 0) + ($s.cached // 0)),
                     "gen_ai.usage.output_tokens": ($s.out // 0),
                     "gen_ai.usage.cache_read.input_tokens": ($s.cached // 0),
                     "gen_ai.usage.cache_creation.input_tokens": ($s.cache_write // 0),
                     "loopwatch.turns": ($s.turns // 0),
                     "error.type": (if $s.is_error then ($s.subtype // "error") else null end),
                     "loopwatch.stage": $s.stage,
                     "loopwatch.prompt_version": $row.prompt_version,
                     "loopwatch.attempt": ($s.attempt // 1),
                     "loopwatch.cost_usd": ($s.cost_usd // 0)
                   } | attrs)} ]
          )}]}]}' "$usage"
}

otel_export() {
  local row="$1" usage="${USAGE_FILE:-/dev/null}" payload run_id
  [[ -n "${OTEL_EXPORT_DIR:-}" || -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]] || return 0
  [[ -f "$usage" ]] || usage=/dev/null
  payload="$(otel_payload "$row" "$usage")" || { log "WARN: otel payload build failed"; return 0; }
  run_id="$(jq -r '.run_id' <<< "$row")"
  if [[ -n "${OTEL_EXPORT_DIR:-}" ]]; then
    mkdir -p "$OTEL_EXPORT_DIR"
    printf '%s\n' "$payload" > "$OTEL_EXPORT_DIR/$run_id.otlp.json" || log "WARN: otel file export failed"
  fi
  if [[ -n "${OTEL_EXPORTER_OTLP_ENDPOINT:-}" ]]; then
    # Headers (usually an API key) go through a 0600 file read by `curl -H @file`, never argv,
    # where any local user could read them via ps or /proc. Parsed per the OTel spec:
    # comma-separated key=value, whitespace trimmed, values percent-decoded.
    local hfile kv k v code
    hfile="$(mktemp "${TMPDIR:-/tmp}/loopwatch-otel.XXXXXX")" || { log "WARN: otel header file"; return 0; }
    chmod 600 "$hfile"
    {
      echo "Content-Type: application/json"
      if [[ -n "${OTEL_EXPORTER_OTLP_HEADERS:-}" ]]; then
        while IFS= read -r kv || [[ -n "$kv" ]]; do
          [[ "$kv" == *=* ]] || continue
          k="$(printf '%s' "${kv%%=*}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          v="$(printf '%s' "${kv#*=}" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
          v="$(printf '%s' "$v" | sed 's/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; v="$(printf '%b' "$v")"
          [[ -n "$k" && "$k" != *[!A-Za-z0-9_-]* ]] || { log "WARN: skipping malformed OTLP header name"; continue; }
          printf '%s: %s\n' "$k" "$v"
        done < <(printf '%s' "$OTEL_EXPORTER_OTLP_HEADERS" | tr ',' '\n')
      fi
    } > "$hfile"
    code="$(printf '%s' "$payload" | curl -sS -o /dev/null -w '%{http_code}' --max-time 5 \
              -X POST -H "@$hfile" --data-binary @- "${OTEL_EXPORTER_OTLP_ENDPOINT%/}/v1/traces" 2>/dev/null || true)"
    rm -f "$hfile"
    [[ "$code" == 2* ]] || log "WARN: OTLP export to collector returned ${code:-no answer}"
  fi
  return 0
}
