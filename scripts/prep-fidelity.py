#!/usr/bin/env python3
"""prep-fidelity.py -- l'image publiee contient-elle ce que prep a construit ?

    prep-fidelity.py <final.tar> <prep.tar>

Deux exports de systeme de fichiers (`docker export`). Pour chaque fichier
regulier de l'image finale, son homologue dans prep est cherche a
`rootfs/<chemin>` (motif /rootfs de la cloture) puis a `<chemin>` ; s'il
existe, les sha256 doivent etre egaux. Un fichier sans homologue vient d'un
autre stage (init Go, sources de l'appli) et n'est pas juge ici.

Pourquoi : uptime-kuma-hardened:2.5.12.0 (2026-11-18) -- le build avait
rejoue prep (nodejs 24.22.3, sonde `node v24.22.3`), mais la couche
`COPY --link --from=prep /rootfs/ /` publiee etait celle du 2026-11-16, a
l'octet : node v24.22.1 dans l'image, 24.22.3-r0 dans la SBOM attestee.
cve-watch et le scan de prep jugeaient donc un contenu qui n'etait pas
publie, et security-audit restait rouge sans qu'aucun automate ne bouge.

Sortie 0 : au moins un fichier compare, aucun ecart. Sortie 1 : un ecart
(liste), ou AUCUN fichier compare -- une porte qui ne compare rien ne prouve
rien. Sortie 2 : usage.
"""
import hashlib
import sys
import tarfile


def empreintes(chemin):
    """{chemin normalise: sha256} des fichiers reguliers (liens durs resolus)."""
    out = {}
    liens = []
    with tarfile.open(chemin) as t:
        for m in t:
            nom = m.name.lstrip("./")
            if m.isreg():
                h = hashlib.sha256()
                f = t.extractfile(m)
                for bloc in iter(lambda: f.read(1 << 20), b""):
                    h.update(bloc)
                out[nom] = h.hexdigest()
            elif m.islnk():
                liens.append((nom, m.linkname.lstrip("./")))
    for nom, cible in liens:
        if cible in out:
            out[nom] = out[cible]
    return out


def comparer(final, prep):
    """(nombre compare, [(chemin, chemin prep, sha final, sha prep)])."""
    compares = 0
    ecarts = []
    for chemin, sha in sorted(final.items()):
        homologue = next((c for c in (f"rootfs/{chemin}", chemin) if c in prep), None)
        if homologue is None:
            continue
        compares += 1
        if prep[homologue] != sha:
            ecarts.append((chemin, homologue, sha, prep[homologue]))
    return compares, ecarts


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2].strip(), file=sys.stderr)
        return 2
    compares, ecarts = comparer(empreintes(argv[1]), empreintes(argv[2]))
    if not compares:
        print("ECHEC -- aucun fichier de l'image n'a d'homologue dans prep : rien n'est prouve")
        return 1
    if ecarts:
        print(f"ECHEC -- {len(ecarts)} fichier(s) de l'image publiee different de ce que prep vient de construire :")
        for chemin, homologue, sf, sp in ecarts[:50]:
            print(f"  /{chemin}  image {sf[:12]}  prep(/{homologue}) {sp[:12]}")
        if len(ecarts) > 50:
            print(f"  ... et {len(ecarts) - 50} autre(s)")
        print("Une couche copiee de prep a ete reprise d'un build anterieur : l'image ne contient pas ce qui a ete scanne.")
        return 1
    print(f"OK -- {compares} fichier(s) de l'image identiques a prep")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
