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

# sonde incomplete
python3 - <<'P'
import json; p=".github/hardened-ci.json"; c=json.load(open(p)); c["probes"]=[{"label":"x","cmd":"true"}]; open(p,"w").write(json.dumps(c))
P
refuse "sonde sans regex" 'probes\[0\]'
exit $fail
