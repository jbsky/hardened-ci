#!/usr/bin/env bash
# Test de hci-config.py : le fichier de description d'un depot doit couvrir les
# sources COPY/ADD (sinon un commit qui ne touche qu'elles ne publie rien), le
# filtre on.push.paths doit couvrir les entrees du compteur (sinon aucun build),
# et la liste d'images de cve-watch doit etre celle que le depot publie (sinon
# l'audit CVE quotidien reste vert sans rien scanner).
set -euo pipefail
H="$(cd "$(dirname "$0")/../../scripts" && pwd)/hci-config.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"; git init -q -b main r; cd r; git config user.email t@t; git config user.name t
mkdir -p conf .github/workflows
echo '{"app":"1.2.3"}' > versions.json
printf 'FROM alpine AS b\nCOPY conf/ /etc/app/\nFROM scratch\nCOPY --from=b /etc/app /etc/app\n' > Dockerfile
echo x > conf/a
cat > .github/hardened-ci.json <<'J'
{"image":"app-hardened","version":{"key":"app"},"revision":["app","Dockerfile","conf/","versions.json"],
 "platforms":["linux/amd64"],"probes":[{"label":"app","cmd":"echo 1.2.3","regex":"[0-9.]+"}]}
J
cat > .github/workflows/build-push.yml <<'W'
on:
  push:
    paths:
      - 'Dockerfile'
      - 'conf/**'
      - 'versions.json'
W
cat > .github/workflows/cve-watch.yml <<'W'
on:
  schedule: [{cron: '30 5 * * *'}]
jobs:
  watch:
    uses: jbsky/hardened-ci/.github/workflows/cve-watch.yml@deadbee # v1.1.0
    permissions:
      contents: write
      issues: write
      packages: read
      actions: write
    with:
      images: '["app-hardened"]'
      selftest: false
W
git add -A; git commit -q -m c1
fail=0
ok() { echo "ok   $*"; }; ko() { echo "FAIL $*"; fail=1; }
# refuse <libelle> <motif attendu dans la sortie> : --check doit echouer et nommer le defaut.
refuse() {
  local out
  if out=$("$H" --check 2>&1); then
    ko "$1 accepte"
  elif grep -q -- "$2" <<<"$out"; then
    ok "$1 refuse"
  else
    ko "$1 : message inattendu : $out"
  fi
}
if "$H" --check >/dev/null 2>&1; then ok "depot conforme accepte"; else ko "depot conforme refuse"; "$H" --check; fi
if [ "$("$H" tag)" = "1.2.3.0" ]; then ok "tag 1.2.3.0"; else ko "tag $("$H" tag)"; fi
if [ "$("$H" want version)" = "1.2.3" ]; then ok "want version"; else ko "want version"; fi

# COPY d'une source absente du compteur
sed -i 's|COPY conf/ /etc/app/|COPY conf/ /etc/app/\nCOPY keys/ /etc/keys/|' Dockerfile; mkdir keys; echo k > keys/k
refuse "COPY keys/ hors compteur" "copie keys"
git checkout -q -- Dockerfile; rm -rf keys

# entree du compteur absente du filtre paths
sed -i "/- 'conf\/\*\*'/d" .github/workflows/build-push.yml
refuse "conf/ hors paths" "conf/ absente du filtre"
git checkout -q -- .github/workflows/build-push.yml

# cve-watch sur un nom que le depot ne publie pas (gabarit laisse tel quel)
sed -i 's|\["app-hardened"\]|["autre-hardened"]|' .github/workflows/cve-watch.yml
refuse "cve-watch sur une image etrangere" "cve-watch audite autre-hardened"
git checkout -q -- .github/workflows/cve-watch.yml

# image publiee absente de la liste de cve-watch
sed -i "s|images: .*|images: '[\"autre-hardened\",\"app-hardened\"]'|" .github/workflows/cve-watch.yml
refuse "image etrangere en plus de la bonne" "cve-watch audite autre-hardened"
git checkout -q -- .github/workflows/cve-watch.yml

# liste vide : refus, pas un saut silencieux
sed -i "s|images: .*|images: '[]'|" .github/workflows/cve-watch.yml
refuse "liste d'images vide" "liste JSON non vide"
git checkout -q -- .github/workflows/cve-watch.yml

# ligne images: absente : refus aussi
sed -i "/images:/d" .github/workflows/cve-watch.yml
refuse "aucune ligne images:" "0 ligne(s)"
git checkout -q -- .github/workflows/cve-watch.yml

# droits du job cve-watch : un bump Dependabot du SHA n'en ajoute aucun, et
# sans eux la reconstruction automatique est refusee en silence cote push.
sed -i '/      actions: write/d' .github/workflows/cve-watch.yml
refuse "cve-watch sans actions: write" "doit accorder actions: write"
git checkout -q -- .github/workflows/cve-watch.yml

sed -i '/    permissions:/,/      actions: write/d' .github/workflows/cve-watch.yml
refuse "cve-watch sans aucun droit" "doit accorder contents: write"
git checkout -q -- .github/workflows/cve-watch.yml

# sonde incomplete
python3 - <<'P'
import json; p=".github/hardened-ci.json"; c=json.load(open(p)); c["probes"]=[{"label":"x","cmd":"true"}]; open(p,"w").write(json.dumps(c))
P
refuse "sonde sans regex" 'probes\[0\]'
git checkout -q -- .github/hardened-ci.json

# =====================================================================
#  Depot a PLUSIEURS images (stack-squid : squid, c-icap, clamav). Chaque
#  image a son Dockerfile, son compteur et ses sondes ; le test est commun,
#  donc les images sont eprouvees ensemble avant qu'aucune soit promue.
# =====================================================================
mkdir -p a/conf b
echo '{"a":"1.0.0","b":"2.0.0"}' > versions.json
printf 'FROM alpine AS s
COPY conf/ /etc/a/
FROM scratch
COPY --from=s /etc/a /etc/a
' > a/Dockerfile
printf 'FROM alpine AS s
FROM scratch
' > b/Dockerfile
echo x > a/conf/x
cat > .github/hardened-ci.json <<'J'
{"platforms":["linux/amd64"],
 "smoke":"./scripts/stack.sh",
 "images":[
   {"key":"a","image":"a-hardened","dockerfile":"a/Dockerfile","compose_service":"a",
    "version":{"key":"a"},"revision":["a","a/","versions.json"],
    "probes":[{"label":"A","cmd":"echo 1.0.0","regex":"[0-9.]+"}]},
   {"key":"b","image":"b-hardened","dockerfile":"b/Dockerfile",
    "version":{"key":"b"},"revision":["b","b/","versions.json"],
    "probes":[{"label":"B","cmd":"echo 2.0.0","regex":"[0-9.]+"}]}]}
J
cat > .github/workflows/build-push.yml <<'W'
on:
  push:
    paths:
      - 'a/**'
      - 'b/**'
      - 'versions.json'
W
sed -i 's|\["app-hardened"\]|["a-hardened","b-hardened"]|' .github/workflows/cve-watch.yml
git add -A; git commit -q -m c2

if "$H" --check >/dev/null 2>&1; then ok "depot multi-images accepte"; else ko "depot multi-images refuse"; "$H" --check; fi
m=$("$H" matrix)
if [ "$(jq -r 'length' <<<"$m")" = 2 ] \
   && [ "$(jq -r '.[0].key' <<<"$m")" = a ] \
   && [ "$(jq -r '.[0].context' <<<"$m")" = a ] \
   && [ "$(jq -r '.[0].manifest' <<<"$m")" = a/image.manifest ] \
   && [ "$(jq -r '.[1].compose_service' <<<"$m")" = '' ]; then
  ok "matrix : contexte, manifeste et service deduits"
else ko "matrix inattendue : $m"; fi
if [ "$("$H" tags)" = '{"a":"1.0.0.0","b":"2.0.0.0"}' ]; then ok "tags des deux images"; else ko "tags $("$H" tags)"; fi
if [ "$("$H" --image b version)" = 2.0.0 ] && [ "$("$H" version)" = 1.0.0 ]; then
  ok "--image selectionne, sans lui la premiere"
else ko "--image : $("$H" --image b version) / $("$H" version)"; fi
if "$H" --image zz version >/dev/null 2>&1; then ko "--image inconnue acceptee"; else ok "--image inconnue refusee"; fi

# le compteur d'une image ne couvre pas ses propres sources
sed -i 's|"revision":\["a","a/","versions.json"\]|"revision":["a","versions.json"]|' .github/hardened-ci.json
refuse "COPY hors compteur de SON image" "images\[a\]"
git checkout -q -- .github/hardened-ci.json

# une image publiee absente de cve-watch
sed -i 's|\["a-hardened","b-hardened"\]|["a-hardened"]|' .github/workflows/cve-watch.yml
refuse "image publiee hors cve-watch" "b-hardened est publiee"
git checkout -q -- .github/workflows/cve-watch.yml

# cle absente, cle en double, image sans champ obligatoire
python3 - <<'P'
import json; p=".github/hardened-ci.json"; c=json.load(open(p)); del c["images"][1]["key"]; open(p,"w").write(json.dumps(c))
P
refuse "image sans cle" "key absente ou invalide"
git checkout -q -- .github/hardened-ci.json
python3 - <<'P'
import json; p=".github/hardened-ci.json"; c=json.load(open(p)); c["images"][1]["key"]="a"; open(p,"w").write(json.dumps(c))
P
refuse "cle en double" "en double"
git checkout -q -- .github/hardened-ci.json
python3 - <<'P'
import json; p=".github/hardened-ci.json"; c=json.load(open(p)); del c["images"][1]["probes"]; open(p,"w").write(json.dumps(c))
P
refuse "image sans sondes" "images\[b\] : champ probes"
git checkout -q -- .github/hardened-ci.json

exit $fail
