#!/usr/bin/env bash
# Test de publish-readme.sh : le commit du bloc de tags du README, pousse apres
# la promotion. Deux runs de build-push peuvent finir en meme temps (un push et
# un dispatch de version-watch, vu sur uptime-kuma-hardened le 2026-11-12) et
# reecrire les MEMES lignes : l'ancien `git pull --rebase || true` laissait un
# rebase en conflit, le job sortait en 1 et ouvrait une issue alors que l'image
# etait publiee. Chaque cas part d'un origin nu et de clones separes, comme
# deux runners.
set -euo pipefail
S="$(cd "$(dirname "$0")/../../scripts" && pwd)"
P="$S/publish-readme.sh"
U="$S/update-readme-tags.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*"; fail=1; }

KUMA=jbsky/uptime-kuma-hardened
SQUID=jbsky/squid-hardened
# Un depot d'origine avec un README deja rendu pour les specs donnees.
nouvel_origin() {  # nouvel_origin <nom> <spec>...
  local n=$1; shift
  git init -q --bare "$T/$n.git"
  git clone -q "$T/$n.git" "$T/$n-seed" 2>/dev/null
  (
    cd "$T/$n-seed"
    git config user.email t@t; git config user.name t; git checkout -q -b main
    printf '# x\n<!-- BEGIN:tags (genere par la CI -- ne pas editer a la main) -->\n<!-- END:tags -->\n' > README.md
    "$U" "$@" > /dev/null
    git add -A; git commit -q -m init; git push -q origin main
  )
}
clone() {  # clone <origin> <dest>  (un runner)
  git clone -q "$T/$1.git" "$T/$2" 2>/dev/null
  git -C "$T/$2" config user.email t@t; git -C "$T/$2" config user.name t
}
ligne() { git -C "$T/$1.git" show main:README.md | grep -F "\`$2\`" | head -1; }
publie() {  # publie <runner> <spec>... ; code de sortie rendu
  ( cd "$T/$1"; shift; "$P" main "$@" ) > "$T/sortie.txt" 2>&1
}

# --- 1. sans course : un commit, pousse ---------------------------------
nouvel_origin a "$KUMA=2.5.9=2.5.9.6"; clone a a1
if publie a1 "$KUMA=2.5.9=2.5.9.7" && ligne a "$KUMA" | grep -q '2.5.9.7'; then
  ok "sans course : README pousse a 2.5.9.7"
else ko "sans course"; cat "$T/sortie.txt"; fi

# --- 2. deja a jour : aucun commit ---------------------------------------
avant=$(git -C "$T/a.git" rev-parse main)
clone a a2
if publie a2 "$KUMA=2.5.9=2.5.9.7" && [ "$(git -C "$T/a.git" rev-parse main)" = "$avant" ]; then
  ok "README deja a jour : rien de pousse"
else ko "README deja a jour"; fi

# --- 3. LE CAS DU 2026-11-12 : meme ligne reecrite entre-temps ----------
nouvel_origin b "$KUMA=2.5.9=2.5.9.6"; clone b bA; clone b bB
publie bA "$KUMA=2.5.9=2.5.9.7"                     # run A finit le premier
if publie bB "$KUMA=2.5.11=2.5.11.0" \
   && ligne b "$KUMA" | grep -q '2.5.11.0' \
   && [ -z "$(git -C "$T/bB" status --porcelain)" ] \
   && ! [ -d "$T/bB/.git/rebase-merge" ] && ! [ -d "$T/bB/.git/rebase-apply" ]; then
  ok "course sur la meme ligne : le run en retard se re-rend sur la tete (2.5.11.0), pas de rebase en suspens"
else ko "course sur la meme ligne"; cat "$T/sortie.txt"; fi

# --- 4. un run en retard n'ecrase JAMAIS un tag plus recent -------------
nouvel_origin c "$KUMA=2.5.9=2.5.9.6"; clone c cA; clone c cB
publie cB "$KUMA=2.5.11=2.5.11.0"                   # le plus recent finit d'abord
if publie cA "$KUMA=2.5.9=2.5.9.7" && ligne c "$KUMA" | grep -q '2.5.11.0'; then
  ok "run plus ancien : le tag plus recent du README reste (sort -V, 2.5.9.7 < 2.5.11.0)"
else ko "run plus ancien ecrase un tag plus recent"; ligne c "$KUMA"; fi

# --- 5. plusieurs images : seule l'image perimee garde la valeur du README
nouvel_origin d "$KUMA=2.5.9=2.5.9.6" "$SQUID=7.5=7.5.1"; clone d dA; clone d dB
publie dB "$KUMA=2.5.11=2.5.11.0" "$SQUID=7.5=7.5.1"
if publie dA "$KUMA=2.5.9=2.5.9.7" "$SQUID=7.5=7.5.2" \
   && ligne d "$KUMA" | grep -q '2.5.11.0' && ligne d "$SQUID" | grep -q '7.5.2'; then
  ok "deux images : kuma garde 2.5.11.0, squid avance a 7.5.2 (le bloc garde ses 2 lignes)"
else ko "deux images"; git -C "$T/d.git" show main:README.md; fi

# --- 6. un push toujours refuse : echec net, pas de boucle infinie ------
nouvel_origin e "$KUMA=2.5.9=2.5.9.6"; clone e e1
printf '#!/bin/sh\nexit 1\n' > "$T/e.git/hooks/pre-receive"; chmod +x "$T/e.git/hooks/pre-receive"
if publie e1 "$KUMA=2.5.9=2.5.9.7"; then ko "push toujours refuse : devait echouer"
elif grep -q "impossible apres 5 essais" "$T/sortie.txt"; then ok "push toujours refuse : echec explicite apres les essais"
else ko "echec sans message"; cat "$T/sortie.txt"; fi

# --- 7. image absente de la table (nouvelle image du depot) : ajoutee, pas de crash
nouvel_origin f "$KUMA=2.5.9=2.5.9.6"; clone f f1
if publie f1 "$KUMA=2.5.9=2.5.9.6" "$SQUID=7.5=7.5.1" \
   && ligne f "$KUMA" | grep -q '2.5.9.6' && ligne f "$SQUID" | grep -q '7.5.1'; then
  ok "image absente du README : ajoutee au bloc, sans crash"
else ko "image absente du README"; cat "$T/sortie.txt"; fi

exit "$fail"
