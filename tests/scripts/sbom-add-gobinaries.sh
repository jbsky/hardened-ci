#!/usr/bin/env bash
# Test de sbom-add-gobinaries.sh : le binaire Go de l'image finale (init de
# bind9-hardened:9.20.29.6, stdlib v1.27.1 -- fige, vulnerable pour toujours)
# doit entrer dans la SBOM prep avec TOUTE sa fermeture, rattache a la racine ;
# une image sans binaire Go ne change rien ; rejouer ne duplique rien.
set -euo pipefail
D="$(cd "$(dirname "$0")/../.." && pwd)"
S="$D/scripts/sbom-add-gobinaries.sh"; F="$D/tests/fixtures/sbom"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ko() { echo "::error::$*"; exit 1; }

"$S" "$F/clean.cdx.json" "$F/final-gobinary.cdx.json" > "$T/merged.json"
n0=$(jq '.components | length' "$F/clean.cdx.json")
n1=$(jq '.components | length' "$T/merged.json")
[ "$n1" -eq $((n0 + 3)) ] || ko "attendu $((n0 + 3)) composants (init, module, stdlib), obtenu $n1"
jq -e 'any(.components[]; .purl == "pkg:golang/stdlib@v1.27.1")' "$T/merged.json" >/dev/null \
  || ko "stdlib absente : fermeture transitive non suivie"
jq -e '.metadata.component."bom-ref" as $r
  | [.components[] | select(.name == "usr/local/bin/init") | ."bom-ref"][0] as $a
  | any(.dependencies[]; .ref == $r and (.dependsOn | index($a)))' "$T/merged.json" >/dev/null \
  || ko "init non rattache a la racine de la SBOM"
echo "ok   init + module + stdlib ajoutes et rattaches"

"$S" "$T/merged.json" "$F/final-gobinary.cdx.json" > "$T/twice.json"
[ "$(jq '.components | length' "$T/twice.json")" -eq "$n1" ] || ko "rejouer a duplique le binaire"
echo "ok   rejouer ne duplique rien"

"$S" "$F/clean.cdx.json" "$F/clean.cdx.json" > "$T/nogo.json"
jq -e --slurpfile a "$F/clean.cdx.json" '. == $a[0]' "$T/nogo.json" >/dev/null \
  || ko "une image sans binaire Go a modifie la SBOM"
echo "ok   image sans binaire Go : SBOM inchangee"
