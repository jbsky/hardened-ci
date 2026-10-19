#!/usr/bin/env bash
# Test de compose-image.sh, dans les deux sens : le service porte l'image du
# depot (le tag sort, pas celui du service dont il depend), ou il porte autre
# chose (echec AVEC le message qui dit lequel des deux noms est faux -- c'est
# tout l'interet du script).
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; S="$R/scripts"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*"; fail=1; }

cat > "$T/docker-compose.yml" <<'Y'
services:
  app:
    image: docker.io/jbsky/app-hardened:latest
    depends_on: [cache]
  cache:
    image: docker.io/library/redis:7
  autre:
    image: gitlab.home.arpa:5050/docker/app:latest
Y
cd "$T"

# --- conforme ---
if got=$("$S/compose-image.sh" app app-hardened 2>&1) && [ "$got" = "docker.io/jbsky/app-hardened:latest" ]; then
  ok "le tag du depot sort, pas celui du service dont il depend"
else ko "tag inattendu : [$got]"; fi

# --- fautif ---
if out=$("$S/compose-image.sh" autre app-hardened 2>&1); then ko "un service qui ne porte pas l'image a ete accepte : [$out]"
elif grep -q '::error::le service autre ne porte pas app-hardened' <<<"$out"; then ok "echec en nommant les deux noms"
else ko "echec muet : [$out]"; fi

# --- service inconnu : le message de docker, et surtout PAS le notre, qui
# accuserait le nom de l'image alors que c'est le service qui n'existe pas ---
if out=$("$S/compose-image.sh" fantome app-hardened 2>&1); then ko "un service inexistant a ete accepte : [$out]"
elif ! grep -q 'no such service' <<<"$out"; then ko "docker n'a pas pu dire pourquoi : [$out]"
elif grep -q '::error::le service' <<<"$out"; then ko "notre message accuse l'image alors que le service n'existe pas : [$out]"
else ok "service inconnu : docker dit pourquoi, sans accusation a cote"; fi

exit $fail
