#!/usr/bin/env bash
# check-prep-fidelity.sh <image finale> <image prep> -- exporte les deux
# systemes de fichiers et passe la main a prep-fidelity.py (voir son en-tete :
# uptime-kuma-hardened:2.5.12.0 publiee avec une couche prep perimee).
set -euo pipefail
FINALE=${1:?usage: check-prep-fidelity.sh <image finale> <image prep>}
PREP=${2:?usage: check-prep-fidelity.sh <image finale> <image prep>}
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

exporter() { # exporter <image> <tar>
  local c
  # Une image FROM scratch n'a ni shell ni commande par defaut : `create`
  # exige une commande, jamais executee ici.
  c=$(docker create "$1" /pas-execute)
  docker export "$c" > "$2"
  docker rm "$c" > /dev/null
}
exporter "$FINALE" "$T/finale.tar"
exporter "$PREP" "$T/prep.tar"
python3 "$HERE/prep-fidelity.py" "$T/finale.tar" "$T/prep.tar"
