#!/usr/bin/env bash
# new-image.sh <destination> -- instancie le gabarit d'image durcie.
#
# Copie template/ puis les scripts partages depuis leur copie de reference
# (scripts/ de ce depot) : le gabarit n'en porte aucune copie qui deriverait.
set -euo pipefail
dest=${1:?usage: new-image.sh <destination>}
root=$(cd "$(dirname "$0")/.." && pwd)
[ -e "$dest" ] && { echo "new-image: $dest existe deja" >&2; exit 1; }
mkdir -p "$dest/scripts"
cp -r "$root/template/." "$dest/"
rm -f "$dest/README.md"
cp "$root/scripts/versions-build-args.py" "$root/scripts/test_versions_build_args.py" "$dest/scripts/"
printf '__pycache__/\n' > "$dest/.gitignore"
# Les appelants des gabarits epinglent la ref de hardened-ci d'ou part ce depot
# (SHA + tag le plus proche) ; Dependabot les fera suivre ensuite.
sha=$(git -C "$root" rev-parse HEAD)
tag=$(git -C "$root" describe --tags --abbrev=0 2>/dev/null || echo "$sha")
sed -i -e "s/@HCI_SHA # HCI_TAG/@${sha} # ${tag}/" "$dest"/.github/workflows/*.yml
echo "gabarit instancie dans $dest -- verifier : (cd $dest && make check)"
