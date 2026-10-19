#!/usr/bin/env bash
# =====================================================================
#  compose-image.sh -- le tag local attendu par les tests : l'image de CE
#  depot, telle que le compose la nomme.
#
#  Pourquoi filtrer : un service qui en depend d'un autre fait sortir
#  plusieurs images a `docker compose config --images`, et un tag pris au
#  hasard ferait tester l'image d'a cote.
#
#  Pourquoi un script : en ligne dans le workflow, l'affectation
#  `tag=$(... | grep ...)` mourait sous `set -euo pipefail` des que le grep
#  ne trouvait rien -- l'etape sortait en 1 SANS le ::error:: qui suit, donc
#  sans dire lequel des deux noms etait faux (vu le 2026-10-19 sur
#  php-fpm-hardened, dont le compose portait encore le registre GitLab mort).
#
#  Usage: compose-image.sh <service-compose> <nom-de-l-image>
# =====================================================================
set -euo pipefail

service=$1
image=$2

tag=$(docker compose config --images "$service" | grep -E "(^|/)${image}(:|@|$)" | head -1 || true)
[ -n "$tag" ] || { echo "::error::le service ${service} ne porte pas ${image}"; exit 1; }
printf '%s\n' "$tag"
