#!/usr/bin/env bash
# Test de prune-ghcr-tags.sh : le DELETE d'une version GHCR. Le 2026-11-11
# (squid-hardened, run 43024405022) un DELETE a pris un 502 et le job est
# sorti en 1 -- image publiee, run rouge, sans qu'aucun commit n'en soit la
# cause. Un 5xx se retente ; un DELETE qui a renvoye 5xx a pu aboutir quand
# meme, donc un 404 au retry compte comme un succes ; toute autre erreur
# (403...) echoue tout de suite, sans retry.
#
# `gh` et `sleep` sont des faux poses en tete du PATH : le listing rend deux
# versions (latest protegee, un auto-* a supprimer) et chaque DELETE consomme
# la ligne suivante d'un scenario (`ok`, `404`, `502`, `403`).
set -euo pipefail
S="$(cd "$(dirname "$0")/../../scripts" && pwd)"
SCRIPT="$S/prune-ghcr-tags.sh"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
fail=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*"; fail=1; }

mkdir -p "$TMPD/bin"
cat > "$TMPD/bin/sleep" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$TMPD/bin/gh" <<'EOF'
#!/usr/bin/env bash
# faux gh : listing fixe, DELETE pilote par $FAKE_DIR/scenario
if [ "$2" != "--method" ]; then
  echo '[{"id":1,"metadata":{"container":{"tags":["latest","2.0.0"]}}},{"id":2,"metadata":{"container":{"tags":["auto-20260101.1"]}}}]'
  exit 0
fi
n=$(cat "$FAKE_DIR/n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_DIR/n"
r=$(sed -n "${n}p" "$FAKE_DIR/scenario")
case "$r" in
  ok)  exit 0 ;;
  404) echo '{"message":"Package version not found.","status":"404"}'; echo 'gh: Package version not found. (HTTP 404)' >&2; exit 1 ;;
  502) echo '{"message": "Server Error"}'; echo 'gh: Server Error (HTTP 502)' >&2; exit 1 ;;
  403) echo '{"message":"Forbidden","status":"403"}'; echo 'gh: Forbidden (HTTP 403)' >&2; exit 1 ;;
  *)   echo "scenario epuise (appel $n)" >&2; exit 99 ;;
esac
EOF
chmod +x "$TMPD/bin/gh" "$TMPD/bin/sleep"

# joue <nom> <reponse>... : rend le code de sortie, le nombre de DELETE dans $TMPD/<nom>/n
joue() {
  local nom=$1; shift
  mkdir -p "$TMPD/$nom"
  printf '%s\n' "$@" > "$TMPD/$nom/scenario"
  FAKE_DIR="$TMPD/$nom" PATH="$TMPD/bin:$PATH" "$SCRIPT" jbsky img 1 > "$TMPD/$nom/sortie" 2>&1
}
appels() { cat "$TMPD/$1/n"; }

# --- 1. sans incident : un DELETE ---------------------------------------
if joue simple ok && [ "$(appels simple)" = 1 ]; then
  ok "DELETE ok du premier coup : 1 appel"
else ko "DELETE simple"; cat "$TMPD/simple/sortie"; fi

# --- 2. LE CAS DU 2026-11-11 : un 502 puis ok -----------------------------
if joue r502 502 ok && [ "$(appels r502)" = 2 ]; then
  ok "502 puis ok : retente, sortie 0"
else ko "502 puis ok"; cat "$TMPD/r502/sortie"; fi

# --- 3. 502 dont le DELETE avait abouti : 404 au retry = succes ----------
if joue r404 502 404 && [ "$(appels r404)" = 2 ]; then
  ok "502 puis 404 : la version est partie, sortie 0"
else ko "502 puis 404"; cat "$TMPD/r404/sortie"; fi

# --- 4. 5xx persistant : echec net et borne, pas de boucle ---------------
if ! joue toujours 502 502 502 502 502 502 502 502 && [ "$(appels toujours)" = 5 ]; then
  ok "502 x5 : sortie non nulle apres 5 essais"
else ko "502 persistant (appels=$(appels toujours))"; cat "$TMPD/toujours/sortie"; fi

# --- 5. 403 : pas un incident transitoire, aucun retry -------------------
if ! joue r403 403 ok && [ "$(appels r403)" = 1 ]; then
  ok "403 : sortie non nulle, aucun retry"
else ko "403 (appels=$(appels r403))"; cat "$TMPD/r403/sortie"; fi

exit "$fail"
