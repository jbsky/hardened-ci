#!/usr/bin/env bash
# Test de check-image-closure.sh et image-manifest.py, dans les deux sens,
# sur des images temoins minuscules construites ici (Docker requis).
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; S="$R/scripts"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok()   { echo "ok   $*"; }
ko()   { echo "FAIL $*"; fail=1; }

docker build -q -t hci-closure-ok "$R/tests/fixtures/closure-ok" >/dev/null
docker build -q -t hci-closure-ko "$R/tests/fixtures/closure-ko" >/dev/null

# --- cloture ---
if "$S/check-image-closure.sh" hci-closure-ok >"$T/c1" 2>&1; then ok "cloture complete acceptee"; else ko "cloture complete refusee"; cat "$T/c1"; fi
if "$S/check-image-closure.sh" hci-closure-ko >"$T/c2" 2>&1; then ko "cloture trouee acceptee"; cat "$T/c2"
elif grep -q 'libssl' "$T/c2"; then ok "cloture trouee refusee (libssl manquante nommee)"
else ko "cloture trouee refusee sans nommer libssl"; cat "$T/c2"; fi
if "$S/check-image-closure.sh" hci-image-qui-nexiste-pas >"$T/c3" 2>&1; then ko "image introuvable acceptee"; else ok "image introuvable refusee"; fi

# --- manifeste ---
"$S/image-manifest.py" --generate hci-closure-ok -o "$T/m" >/dev/null
if "$S/image-manifest.py" --check hci-closure-ok -m "$T/m" >"$T/m1" 2>&1; then ok "manifeste identique accepte"; else ko "manifeste identique refuse"; cat "$T/m1"; fi
# Meme image + un fichier : la derive doit echouer.
printf 'FROM hci-closure-ok\nCOPY extra /etc/extra\n' > "$T/Dockerfile"; echo x > "$T/extra"
docker build -q -t hci-closure-plus "$T" >/dev/null
if "$S/image-manifest.py" --check hci-closure-plus -m "$T/m" >"$T/m2" 2>&1; then ko "fichier ajoute non detecte"; cat "$T/m2"
elif grep -q 'etc/extra' "$T/m2"; then ok "fichier ajoute detecte (etc/extra nomme)"
else ko "derive refusee sans nommer etc/extra"; cat "$T/m2"; fi

# --- rapport (--report) : lu sur le manifeste, jamais sur l'image ---
if "$S/image-manifest.py" --report -m "$T/m" --name hci-closure-ok >"$T/r" 2>&1 \
   && grep -q 'hci-closure-ok' "$T/r" && grep -q 'bin/busybox' "$T/r" && grep -q -i 'elf' "$T/r"; then
  ok "rapport Markdown : nom, fichier ELF et busybox presents"
else ko "rapport incomplet"; cat "$T/r"; fi
if "$S/image-manifest.py" --report -m "$T/absent" >"$T/r2" 2>&1; then ko "rapport sur un manifeste absent accepte"; else ok "rapport sur un manifeste absent refuse"; fi

docker rmi -f hci-closure-ok hci-closure-ko hci-closure-plus >/dev/null 2>&1 || true
exit $fail
