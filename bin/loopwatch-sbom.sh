#!/usr/bin/env bash
# loopwatch-sbom.sh [tree-root] — SPDX 2.3 JSON SBOM for a loopwatch release (SOTA backlog #30).
# Dependency-free (bash + jq + sha256sum/shasum). Describes:
#   * the loopwatch package: version, license, and every shipped file with its SHA-256
#     (git-tracked files when run in a clone, else every regular file under the root), with
#     SHA1 + SHA256 and the SPDX package verification code;
#   * its runtime requirements as packages it DEPENDS_ON: bash, jq, git, curl, Claude Code CLI;
#   * the GitHub Actions the release is built with (pinned SHAs, read from the workflows) as
#     BUILD_TOOL_OF relationships.
# The release workflow attaches the result to the release and attests it (build provenance).
# SOURCE_DATE_EPOCH, when set, fixes the "created" timestamp so the SBOM is reproducible.
set -euo pipefail
ROOT="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")/..}" && pwd)"
VERSION="$(tr -d ' \n' < "$ROOT/VERSION")"
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -c1-64; else shasum -a 256 "$1" | cut -c1-64; fi; }
sha1() { if command -v sha1sum >/dev/null 2>&1; then sha1sum "$1" | cut -c1-40; else shasum -a 1 "$1" | cut -c1-40; fi; }

if git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  list() { git -C "$ROOT" ls-files; }
else
  list() { (cd "$ROOT" && find . -type f ! -path './.git/*' | sed 's|^\./||' | LC_ALL=C sort); }
fi
files="$(list | while IFS= read -r f; do
  [[ -f "$ROOT/$f" ]] || continue
  jq -nc --arg f "$f" --arg h "$(sha "$ROOT/$f")" --arg h1 "$(sha1 "$ROOT/$f")" \
    '{fileName: ("./" + $f), checksums: [{algorithm: "SHA1", checksumValue: $h1}, {algorithm: "SHA256", checksumValue: $h}]}'
done | jq -sc '.')"
actions="$(grep -hoE 'uses:[[:space:]]*[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}([[:space:]]+#[[:space:]]*v[0-9][^[:space:]]*)?' \
             "$ROOT"/.github/workflows/*.yml 2>/dev/null \
           | sed -E 's/^uses:[[:space:]]*//; s/[[:space:]]+#[[:space:]]*/ /' | LC_ALL=C sort -u \
           | jq -Rsc 'split("\n") | map(select(length > 0) | split(" ") | {ref: .[0], tag: (.[1] // "")})')"
# SPDX package verification code: SHA1 over the sorted, concatenated file SHA1s (spec 7.9)
pvc="$(jq -r '.[].checksums[] | select(.algorithm == "SHA1") | .checksumValue' <<< "$files" | LC_ALL=C sort | tr -d '\n' \
       | { if command -v sha1sum >/dev/null 2>&1; then sha1sum; else shasum -a 1; fi; } | cut -c1-40)"
created="$(if [[ -n "${SOURCE_DATE_EPOCH:-}" ]]; then jq -nr --argjson t "$SOURCE_DATE_EPOCH" '$t | todate'; else date -u +%Y-%m-%dT%H:%M:%SZ; fi)"

jq -n --arg pvc "$pvc" --arg v "$VERSION" --arg created "$created" --argjson files "$files" --argjson actions "$actions" '
  def spdxid: gsub("[^A-Za-z0-9.-]"; "-");
  def req($name; $ver; $url): {SPDXID: ("SPDXRef-Req-" + ($name | spdxid)), name: $name, versionInfo: $ver,
    downloadLocation: $url, filesAnalyzed: false, licenseConcluded: "NOASSERTION", copyrightText: "NOASSERTION",
    primaryPackagePurpose: "APPLICATION", comment: "runtime requirement (not bundled)"};
  ($files | to_entries | map(.value + {SPDXID: ("SPDXRef-File-" + (.key | tostring)),
     licenseConcluded: "NOASSERTION", copyrightText: "NOASSERTION"})) as $f
  | [ req("bash"; ">=3.2"; "https://www.gnu.org/software/bash/"),
      req("jq"; ">=1.6"; "https://github.com/jqlang/jq"),
      req("git"; ">=2.20"; "https://git-scm.com/"),
      req("curl"; ">=7.55"; "https://curl.se/"),
      req("claude-code-cli"; ">=2.1"; "https://www.npmjs.com/package/@anthropic-ai/claude-code") ] as $reqs
  | ($actions | map({SPDXID: ("SPDXRef-Action-" + (.ref | spdxid)), name: (.ref | split("@")[0]),
       versionInfo: (if .tag == "" then (.ref | split("@")[1]) else .tag end),
       downloadLocation: ("git+https://github.com/" + (.ref | split("@")[0]) + "@" + (.ref | split("@")[1])),
       filesAnalyzed: false, licenseConcluded: "NOASSERTION", copyrightText: "NOASSERTION",
       externalRefs: [{referenceCategory: "PACKAGE-MANAGER", referenceType: "purl",
         referenceLocator: ("pkg:githubactions/" + (.ref | split("@")[0]) + "@" + (.ref | split("@")[1]))}]})) as $acts
  | {
    spdxVersion: "SPDX-2.3", dataLicense: "CC0-1.0", SPDXID: "SPDXRef-DOCUMENT",
    name: ("loopwatch-" + $v),
    documentNamespace: ("https://github.com/adventurewave-labs/loopwatch-v2/sbom/loopwatch-" + $v),
    creationInfo: {created: $created, creators: ["Tool: loopwatch-sbom.sh"]},
    packages: ([{SPDXID: "SPDXRef-Package-loopwatch", name: "loopwatch", versionInfo: $v,
                 downloadLocation: ("git+https://github.com/adventurewave-labs/loopwatch-v2@v" + $v),
                 filesAnalyzed: true, licenseConcluded: "MIT", licenseDeclared: "MIT", copyrightText: "NOASSERTION",
                 primaryPackagePurpose: "APPLICATION",
                 packageVerificationCode: {packageVerificationCodeValue: $pvc},
                 hasFiles: ($f | map(.SPDXID))}] + $reqs + $acts),
    files: $f,
    relationships: ([{spdxElementId: "SPDXRef-DOCUMENT", relationshipType: "DESCRIBES", relatedSpdxElement: "SPDXRef-Package-loopwatch"}]
      + ($reqs | map({spdxElementId: "SPDXRef-Package-loopwatch", relationshipType: "DEPENDS_ON", relatedSpdxElement: .SPDXID}))
      + ($acts | map({spdxElementId: .SPDXID, relationshipType: "BUILD_TOOL_OF", relatedSpdxElement: "SPDXRef-Package-loopwatch"})))
  }'
