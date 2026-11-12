#!/usr/bin/env bash
#
# Rend le bloc de tags du README et le pousse sur la branche par defaut.
#
# Usage: publish-readme.sh <branche> <image>=<version>=<tag-immuable> [...]
#
# Le README est une DONNEE DERIVEE : il se regenere a partir des specs, il ne
# se fusionne pas. Quand le push est refuse (un autre run a ecrit entre-temps,
# par exemple un push et un dispatch de version-watch qui finissent ensemble),
# on ne rebase donc PAS notre commit -- deux runs reecrivent les memes lignes,
# le rebase tombe en conflit de contenu et le job sort en 1 alors que l'image
# est publiee (uptime-kuma-hardened, 2026-11-12). On jette notre commit, on se
# replace sur la tete de la branche et on re-rend.
#
# Un run en retard ne doit pas non plus FAIRE RECULER le README : si la ligne
# d'une image porte deja un tag plus recent que le notre (ordre `sort -V`,
# 2.5.9.7 < 2.5.11.0), cette image garde la valeur du README. Le bloc se rend
# d'un seul tenant, une image omise en disparaitrait : on lui rejoue sa propre
# valeur plutot que de la retirer des specs.
#
# L'abandon du commit est un `reset --hard` : prevu pour un runner jetable ou
# le seul commit local est celui de ce script.
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <branche> <image>=<version>=<tag> [...]" >&2
  exit 2
fi
BRANCH="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
README="${README:-README.md}"
ESSAIS="${PUBLISH_README_ESSAIS:-5}"

# Valeur (version|tag) que le README nomme deja pour <image>, ou rien.
# Aucun lecteur a sortie precoce derriere le tuyau (`head -1`) : sous pipefail
# l'ecrivain meurt de SIGPIPE. Et une image absente de la table (nouvelle image
# du depot) n'est pas une erreur : le grep sans correspondance sort en 1.
courante() {
  local img="$1" lignes
  # SC2016 : les accents graves sont du Markdown litteral, pas une substitution.
  # shellcheck disable=SC2016
  lignes=$(grep -F -- "| \`${img}\` |" "$README" 2>/dev/null \
    | sed -nE 's/^\| `[^`]*` \| `([^`]*)` \| `([^`]*)` \|.*/\1|\2/p') || true
  printf '%s\n' "${lignes%%$'\n'*}"
}

# specs retenues : la notre, sauf si le README a deja un tag strictement plus recent.
retenir() {
  local spec img rev cur cver crev plus
  retenues=()
  for spec in "$@"; do
    IFS='=' read -r img _ rev <<<"$spec"
    cur=$(courante "$img")
    if [ -n "$cur" ]; then
      cver="${cur%%|*}"; crev="${cur##*|}"
      plus=$(printf '%s\n%s\n' "$crev" "$rev" | sort -V | tail -n 1)
      if [ "$crev" != "$rev" ] && [ "$plus" = "$crev" ]; then
        echo "$img : le README nomme deja $crev, plus recent que $rev -- inchange"
        retenues+=("${img}=${cver}=${crev}")
        continue
      fi
    fi
    retenues+=("$spec")
  done
}

for essai in $(seq 1 "$ESSAIS"); do
  retenir "$@"
  "$HERE/update-readme-tags.sh" "${retenues[@]}"
  if git diff --quiet -- "$README"; then
    echo "README already names the current tag"
    exit 0
  fi
  git add -- "$README"
  git commit -q -m "docs(readme): tag immuable courant [skip ci]"
  if git push -q origin "HEAD:${BRANCH}"; then
    exit 0
  fi
  echo "push refuse (essai ${essai}/${ESSAIS}) -- commit abandonne, re-rendu sur la tete de ${BRANCH}"
  git fetch -q origin "$BRANCH"
  git reset -q --hard FETCH_HEAD
done
echo "::error::push du README impossible apres ${ESSAIS} essais"
exit 1
