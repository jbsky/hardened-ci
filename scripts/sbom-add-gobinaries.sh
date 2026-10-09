#!/usr/bin/env bash
# =====================================================================
#  sbom-add-gobinaries.sh <prep.cdx.json> <final.cdx.json>
#
#  Prints the prep SBOM with the Go binaries of the final image added: every
#  `application` component Trivy typed `gobinary`, plus the TRANSITIVE closure
#  of what it depends on (init -> module -> stdlib: without the closure stdlib
#  is missing and the scan reports 0 CVE).
#
#  Why: the attested SBOM is the prep stage's, the only stage a scanner can
#  read. Most images COPY the static Go `init` straight from gobuilder into
#  the FROM scratch stage, so prep never sees it, and cve-watch was blind to
#  Go stdlib CVEs on 6 images out of 8 (CVE-2026-78667, 2026-10-09: only
#  bind9 and varnish -- which also copy init into prep -- were alerted).
#
#  Only Go binaries are taken from the final image, nothing else: its other
#  packages are either in prep already or deliberately out of cve-watch
#  (uptime-kuma's npm dependencies, handled by derogations in its own scan).
#  A binary prep already lists (same name) is not added twice.
# =====================================================================
set -euo pipefail

PREP="${1:?usage: sbom-add-gobinaries.sh <prep.cdx.json> <final.cdx.json>}"
FINAL="${2:?usage: sbom-add-gobinaries.sh <prep.cdx.json> <final.cdx.json>}"

jq --slurpfile final "$FINAL" '
  def gobins: [.components[]? | select(.type == "application"
    and any(.properties[]?; .name == "aquasecurity:trivy:Type" and .value == "gobinary"))];
  ($final[0]) as $f
  | ([gobins[].name]) as $known
  | ([$f.dependencies[]? | {key: .ref, value: (.dependsOn // [])}] | from_entries) as $g
  | [$f | gobins[] | select(.name as $n | $known | index($n) | not) | ."bom-ref"] as $apps
  | ($apps | [recurse(map($g[.][]?) | select(length > 0))] | add // [] | unique) as $refs
  | .metadata.component."bom-ref" as $root
  | .components += [$f.components[]? | select(."bom-ref" as $r | $refs | index($r))]
  | .dependencies = ((.dependencies // [])
      | map(if .ref == $root then .dependsOn = ((.dependsOn // []) + $apps) else . end))
      + [$f.dependencies[]? | select(.ref as $r | $refs | index($r))]
' "$PREP"
