#!/usr/bin/env bash
# Test de build-revision.sh : le compteur de revision fait le tag immuable
# <version>.<revision> de chaque image. Un compte faux republie sous un tag
# existant (que la garde refuse : plus aucune publication, en vert) ou saute
# un numero. Chaque forme d'appel des depots est verifiee sur un historique
# git connu, puis le refus du clone superficiel.
set -euo pipefail
BR="$(cd "$(dirname "$0")/../../scripts" && pwd)/build-revision.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cd "$T"; git init -q -b main repo; cd repo
git config user.email t@t; git config user.name t
c() { git add -A; git commit -q -m "$1"; }
fail=0
expect() {  # expect <attendu> <libelle> <args...>
  local want=$1 label=$2; shift 2
  local got; got=$("$BR" "$@" 2>&1) || got="ERREUR($got)"
  if [ "$got" = "$want" ]; then echo "ok   $label = $got"; else echo "FAIL $label : attendu $want, obtenu $got"; fail=1; fi
}

mkdir conf
echo '{"app":"1.0"}' > versions.json; echo 'FROM php:8.5.1-fpm-alpine' > Dockerfile; echo a > conf/a; c c1
echo b > conf/a; c c2
echo doc > README.md; c c3                       # hors des entrees
echo 'FROM php:8.5.2-fpm-alpine' > Dockerfile; c c4

expect 2 "positionnel (versions.json)" app Dockerfile conf/
expect 0 "--source --grep (ligne FROM)" --source Dockerfile --grep '^FROM php:\K[0-9.]+' -- Dockerfile conf/
expect 3 "--unanchored" --unanchored -- Dockerfile conf/

echo '{"app":"1.1"}' > versions.json; c c5     # montee de version : le compteur repart
echo c > conf/a; c c6

expect 1 "positionnel apres montee" app Dockerfile conf/
expect 1 "--source --grep apres c6" --source Dockerfile --grep '^FROM php:\K[0-9.]+' -- Dockerfile conf/
expect 4 "--unanchored apres c6" --unanchored -- Dockerfile conf/

# Clone superficiel : refuse, jamais un .0 silencieux.
cd "$T"; git clone -q --depth 1 "file://$T/repo" shallow; cd shallow
if out=$("$BR" app Dockerfile conf/ 2>&1); then
  echo "FAIL clone superficiel accepte ($out)"; fail=1
else
  echo "ok   clone superficiel refuse"
fi
exit $fail
