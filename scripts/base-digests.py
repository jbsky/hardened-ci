#!/usr/bin/env python3
"""base-digests.py -- releve et met a jour les digests des images de base.

Les `FROM` du parc ecrivent tag ET digest en dur (`alpine:3.24@sha256:...`) :
le tag documente, le digest est ce qui est reellement construit. L'amont
republie ce meme tag -- `golang:1.27-alpine` a change de digest 3 fois en
2026 -- et rien dans le depot ne le voit : Dependabot n'a propose le dernier
mouvement que sur 1 depot sur 8 (une PR de bump FERMEE lui interdit de
reproposer la meme dependance).

Ce script fait, pour le socle, ce que version-watch fait pour les versions
amont : relever le digest courant de chaque `image:tag` reference, et le
reecrire. Le tag n'est jamais touche -- passer de 1.27 a 1.28 reste une
decision humaine (PR Dependabot).

    base-digests.py                       releve, JSON sur stdout
    base-digests.py --update              reecrit les fichiers
    base-digests.py --update Dockerfile   sur les fichiers donnes

Le JSON porte `subject`, le sujet de commit tout prepare : apres `--update`
un second appel ne verrait plus aucune derive et renverrait un sujet vide.

Sans argument de fichier : tous les fichiers suivis par git dont le nom
commence par « Dockerfile ».

Aucune dependance hors stdlib. Une resolution impossible, un digest mal
forme ou un manifeste mono-architecture sont des ERREURS : ecrire un digest
mono-arch casserait les builds arm64, et sauter en silence rendrait la
veille verte sans rien verifier.
"""
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

# Un digest de ligne FROM doit designer un index multi-architecture.
INDEX_TYPES = (
    "application/vnd.oci.image.index.v1+json",
    "application/vnd.docker.distribution.manifest.list.v2+json",
)
ACCEPT = ", ".join(INDEX_TYPES + (
    "application/vnd.oci.image.manifest.v1+json",
    "application/vnd.docker.distribution.manifest.v2+json",
))
DIGEST_RE = re.compile(r"^sha256:[0-9a-f]{64}$")
# FROM [--platform=...] <image>[:<tag>]@sha256:<digest> [AS <nom>]
FROM_RE = re.compile(
    r"^(?P<head>FROM\s+(?:--\S+\s+)*)(?P<ref>[^\s@]+)@(?P<digest>sha256:[0-9a-f]+)(?P<tail>\s.*)?$"
)


def parse_ref(ref):
    """« alpine:3.24 » -> (« library/alpine », « 3.24 »). docker.io seulement."""
    name, _, tag = ref.partition(":")
    if "/" in name:
        host, _, rest = name.partition("/")
        if "." in host or ":" in host or host == "localhost":
            if host not in ("docker.io", "index.docker.io"):
                raise SystemExit(f"base-digests: {ref} : registre {host} non gere "
                                 f"(docker.io seulement -- l'ajouter plutot que sauter)")
            name = rest
    if "/" not in name:
        name = f"library/{name}"
    return name, (tag or "latest")


def fetch_digest(ref):
    """Digest d'index courant de <ref>, lu sur le registre."""
    repo, tag = parse_ref(ref)
    try:
        with urllib.request.urlopen(
            "https://auth.docker.io/token?service=registry.docker.io"
            f"&scope=repository:{repo}:pull", timeout=30
        ) as r:
            token = json.load(r)["token"]
        req = urllib.request.Request(
            f"https://registry-1.docker.io/v2/{repo}/manifests/{tag}",
            method="HEAD", headers={"Authorization": f"Bearer {token}", "Accept": ACCEPT},
        )
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.headers.get("Docker-Content-Digest"), r.headers.get("Content-Type", "")
    except (urllib.error.URLError, OSError, ValueError, KeyError) as e:
        raise SystemExit(f"base-digests: {ref} : digest courant illisible ({e})")


def resolve(ref, fetch=fetch_digest):
    digest, ctype = fetch(ref)
    if not digest or not DIGEST_RE.match(digest):
        raise SystemExit(f"base-digests: {ref} : digest renvoye invalide ({digest!r})")
    if ctype.split(";")[0].strip() not in INDEX_TYPES:
        raise SystemExit(f"base-digests: {ref} : {ctype} n'est pas un index multi-architecture "
                         f"-- un digest mono-arch casserait les builds arm64")
    return digest


def dockerfiles():
    out = subprocess.run(["git", "ls-files"], capture_output=True, text=True, check=True).stdout
    return [f for f in out.splitlines() if Path(f).name.startswith("Dockerfile")]


def scan(files):
    """{ref: {digest: [fichiers]}} pour les FROM qui portent un digest."""
    refs = {}
    for f in files:
        for line in Path(f).read_text().splitlines():
            m = FROM_RE.match(line.strip())
            if m:
                refs.setdefault(m["ref"], {}).setdefault(m["digest"], []).append(f)
    return refs


def rewrite(f, ref, digest):
    p = Path(f)
    out, n = [], 0
    for line in p.read_text().splitlines(keepends=True):
        m = FROM_RE.match(line.strip())
        if m and m["ref"] == ref and m["digest"] != digest:
            line = line.replace(f'{ref}@{m["digest"]}', f"{ref}@{digest}")
            n += 1
        out.append(line)
    if n:
        p.write_text("".join(out))
    return n


def subject(changed):
    """Sujet de commit : « build(base): golang:1.27-alpine 738d1cf -> f92b6ef »."""
    if not changed:
        return ""
    parts = [f'{c["image"]} {c["old"][7:14]} -> {c["new"][7:14]}' for c in changed]
    return "build(base): " + ", ".join(parts)


def run(files, update=False, fetch=fetch_digest):
    refs = scan(files)
    changed, unchanged = [], []
    for ref in sorted(refs):
        current = resolve(ref, fetch)
        for old in sorted(refs[ref]):
            touched = sorted(set(refs[ref][old]))
            if old == current:
                unchanged.append({"image": ref, "digest": current, "files": touched})
                continue
            entry = {"image": ref, "old": old, "new": current, "files": touched}
            if update:
                entry["rewritten"] = sum(rewrite(f, ref, current) for f in touched)
            changed.append(entry)
    return {"changed": changed, "unchanged": unchanged, "subject": subject(changed)}


def main(argv):
    if {"--help", "-h"} & set(argv[1:]):
        print(__doc__)
        return 0
    args = [a for a in argv[1:] if not a.startswith("-")]
    flags = {a for a in argv[1:] if a.startswith("-")}
    unknown = flags - {"--update"}
    if unknown:
        raise SystemExit(f"base-digests: option inconnue : {' '.join(sorted(unknown))}")
    files = args or dockerfiles()
    if not files:
        raise SystemExit("base-digests: aucun Dockerfile")
    print(json.dumps(run(files, update="--update" in flags), indent=2, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
