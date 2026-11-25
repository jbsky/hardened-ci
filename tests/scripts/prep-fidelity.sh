#!/usr/bin/env bash
# Test de prep-fidelity.py : l'image publiee contient-elle ce que prep a
# construit ? Le 2026-11-18, uptime-kuma-hardened:2.5.12.0 a ete publiee avec
# la couche prep du 2026-11-16 (node v24.22.1) alors que le build avait
# reconstruit prep (node v24.22.3) : SBOM, scan et cve-watch jugeaient un
# contenu absent de l'image. Archives synthetiques, aucun docker.
set -euo pipefail
S="$(cd "$(dirname "$0")/../../scripts" && pwd)"
P="$S/prep-fidelity.py"
TMPD=$(mktemp -d); trap 'rm -rf "$TMPD"' EXIT
fail=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*"; fail=1; }

# tarball <sortie> <chemin=contenu>... ; un contenu "@cible" fait un lien dur
tarball() {
  python3 - "$@" <<'PY'
import io, sys, tarfile
out, *entrees = sys.argv[1:]
with tarfile.open(out, "w") as t:
    for e in entrees:
        nom, contenu = e.split("=", 1)
        if contenu.startswith("@"):
            i = tarfile.TarInfo(nom); i.type = tarfile.LNKTYPE; i.linkname = contenu[1:]
            t.addfile(i)
        else:
            b = contenu.encode(); i = tarfile.TarInfo(nom); i.size = len(b)
            t.addfile(i, io.BytesIO(b))
PY
}
joue() { python3 "$P" "$TMPD/$1-final.tar" "$TMPD/$1-prep.tar" > "$TMPD/$1.out" 2>&1; }

# --- 1. fidele : motif /rootfs, plus un fichier d'un autre stage --------------
tarball "$TMPD/f-final.tar" "usr/bin/node=v24.22.3" "usr/local/bin/init=go" "app/server.js=js"
tarball "$TMPD/f-prep.tar" "rootfs/usr/bin/node=v24.22.3" "usr/bin/node=v24.22.3" "etc/apk/world=x"
if joue f && grep -q 'OK -- 1 fichier' "$TMPD/f.out"; then ok "image fidele a prep : sortie 0, seuls les homologues comptes"
else ko "fidele"; cat "$TMPD/f.out"; fi

# --- 2. LE CAS DU 2026-11-18 : couche prep perimee ---------------------------
tarball "$TMPD/k-final.tar" "usr/bin/node=v24.22.1" "usr/lib/libssl.so.3=ancien"
tarball "$TMPD/k-prep.tar" "rootfs/usr/bin/node=v24.22.3" "rootfs/usr/lib/libssl.so.3=ancien"
if ! joue k && grep -q '/usr/bin/node' "$TMPD/k.out" && ! grep -q 'libssl' "$TMPD/k.out"; then
  ok "node perime dans l'image : sortie 1, seul l'ecart est liste"
else ko "couche perimee"; cat "$TMPD/k.out"; fi

# --- 3. /rootfs prime sur le chemin brut de prep ------------------------------
# /etc/passwd de l'image vient de la cloture (/rootfs), pas du passwd complet
# du stage : le comparer au second serait un faux rouge.
tarball "$TMPD/r-final.tar" "etc/passwd=reduit"
tarball "$TMPD/r-prep.tar" "rootfs/etc/passwd=reduit" "etc/passwd=complet"
if joue r; then ok "homologue /rootfs prefere au chemin brut"
else ko "priorite /rootfs"; cat "$TMPD/r.out"; fi

# --- 4. rien en commun : la porte ne prouve rien, elle echoue -----------------
tarball "$TMPD/v-final.tar" "usr/local/bin/init=go"
tarball "$TMPD/v-prep.tar" "rootfs/usr/bin/node=v24.22.3"
if ! joue v && grep -q 'aucun fichier' "$TMPD/v.out"; then ok "aucun homologue : sortie 1"
else ko "aucun homologue"; cat "$TMPD/v.out"; fi

# --- 5. lien dur (docker export) : compare par son contenu --------------------
tarball "$TMPD/l-final.tar" "usr/bin/node=v24.22.1" "usr/bin/nodejs=@usr/bin/node"
tarball "$TMPD/l-prep.tar" "rootfs/usr/bin/node=v24.22.1" "rootfs/usr/bin/nodejs=v24.22.3"
if ! joue l && grep -q '/usr/bin/nodejs' "$TMPD/l.out"; then ok "lien dur resolu et compare"
else ko "lien dur"; cat "$TMPD/l.out"; fi

exit "$fail"
