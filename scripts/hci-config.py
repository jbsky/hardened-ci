#!/usr/bin/env python3
"""hci-config.py -- lit .github/hardened-ci.json, le fichier unique ou un depot
d'image decrit ce qui le distingue des autres (nom, lecture de la version,
entrees du compteur de revision, plateformes, sondes, tests).

Les gabarits build-push et security-audit le lisent tous deux : les arguments du
compteur ne sont plus ecrits qu'une fois (l'audit nginx calculait 1.30.5.18 quand
la CI publiait 1.30.5.20, faute de cette unicite).

    hci-config.py get <champ>        valeur d'un champ (JSON compact si non textuel)
    hci-config.py version            version de l'image
    hci-config.py want <cle>         valeur attendue d'une sonde (version, ou cle de versions.json)
    hci-config.py tag                <version>.<revision> (build-revision.sh)
    hci-config.py --check            controle du fichier (voir check())

Aucune dependance hors stdlib. A lancer a la racine du depot d'image.
"""
import fnmatch
import json
import re
import subprocess
import sys
from pathlib import Path

CONF = Path(".github/hardened-ci.json")
HERE = Path(__file__).resolve().parent
REQUIRED = {"image": str, "version": dict, "revision": list, "platforms": list, "probes": list}
DEFAULTS = {"compose_service": None, "smoke": None, "validate_on_pr": False}


def load():
    try:
        c = json.loads(CONF.read_text())
    except (OSError, ValueError) as e:
        raise SystemExit(f"hci-config: {CONF} illisible : {e}")
    for k, t in REQUIRED.items():
        if not isinstance(c.get(k), t):
            raise SystemExit(f"hci-config: {CONF} : champ {k} absent ou de mauvais type ({t.__name__} attendu)")
    for k, v in DEFAULTS.items():
        c.setdefault(k, v)
    return c


def read_version(spec):
    if "key" in spec:
        v = json.loads(Path("versions.json").read_text()).get(spec["key"], "")
    else:
        text = Path(spec["file"]).read_text()
        out = subprocess.run(["grep", "-oP", spec["grep"]], input=text, capture_output=True, text=True).stdout
        v = out.splitlines()[0] if out.strip() else ""
    if not isinstance(v, str) or not v.strip():
        raise SystemExit(f"hci-config: version introuvable ({spec})")
    return v.strip()


def tag(c):
    rev = subprocess.run([str(HERE / "build-revision.sh"), *c["revision"]], capture_output=True, text=True)
    if rev.returncode != 0:
        raise SystemExit(f"hci-config: build-revision.sh a echoue : {rev.stderr.strip()}")
    return f"{read_version(c['version'])}.{rev.stdout.strip()}"


def revision_paths(c):
    """Les chemins d'entree du compteur (ce qui suit `--`, ou apres la cle positionnelle)."""
    a = c["revision"]
    if "--" in a:
        return a[a.index("--") + 1:]
    return a[1:]


def copy_sources(dockerfile):
    """Sources COPY/ADD tirees du contexte (pas --from, pas d'URL)."""
    text = re.sub(r"\\\n", " ", Path(dockerfile).read_text())
    srcs = []
    for line in text.splitlines():
        m = re.match(r"^\s*(COPY|ADD)\s+(.*)$", line, re.I)
        if not m:
            continue
        toks = [t for t in m.group(2).split() if not t.startswith("--")]
        if any(t.startswith("--from") for t in m.group(2).split()):
            continue
        for s in toks[:-1]:
            if not re.match(r"^[a-z]+://", s):
                srcs.append(s.rstrip("/"))
    return srcs


def covered(path, inputs):
    p = path.rstrip("/")
    for i in inputs:
        i = i.rstrip("/")
        if p == i or p.startswith(i + "/"):
            return True
    return False


def push_paths(wf):
    """Le filtre on.push.paths du workflow appelant (lecture texte, sans PyYAML)."""
    lines = Path(wf).read_text().splitlines()
    out, inside, ind = [], False, None
    for l in lines:
        if re.match(r"^\s{4}paths:\s*$", l) and not out:
            inside, ind = True, len(l) - len(l.lstrip())
            continue
        if inside:
            m = re.match(r"^\s*-\s*['\"]?([^'\"#]+?)['\"]?\s*(#.*)?$", l)
            if m and len(l) - len(l.lstrip()) > ind:
                out.append(m.group(1).strip())
            elif l.strip() and not l.lstrip().startswith("#"):
                break
    return out


def check(c):
    errors = []
    try:
        read_version(c["version"])
    except SystemExit as e:
        errors.append(str(e))
    ins = revision_paths(c)
    if not ins:
        errors.append("revision : aucun chemin d'entree")
    for d in sorted({p["dockerfile"] for p in c.get("images_extra", [])} | {c.get("dockerfile", "Dockerfile")}):
        for s in copy_sources(d):
            if not covered(s, ins):
                errors.append(f"{d} copie {s}, absent des entrees du compteur ({' '.join(ins)}) : "
                              f"un commit qui ne touche que lui ne publierait rien")
    wf = Path(".github/workflows/build-push.yml")
    if wf.exists():
        pp = push_paths(wf)
        if pp:
            for i in ins:
                probe = i.rstrip("/") + ("/x" if i.endswith("/") else "")
                if not any(fnmatch.fnmatch(probe, g) or probe == g for g in pp):
                    errors.append(f"entree du compteur {i} absente du filtre on.push.paths : "
                                  f"un commit qui ne touche qu'elle ne declencherait aucun build")
    for i, p in enumerate(c["probes"]):
        if not isinstance(p, dict) or not p.get("cmd") or not (p.get("regex") or p.get("expect")):
            errors.append(f"probes[{i}] : cmd et regex (ou expect) obligatoires")
    for pl in c["platforms"]:
        if pl not in ("linux/amd64", "linux/arm64"):
            errors.append(f"platforms : {pl} inconnu (linux/amd64, linux/arm64)")
    if "linux/amd64" not in c["platforms"]:
        errors.append("platforms : linux/amd64 obligatoire (seule plateforme testee)")
    return errors


def main(argv):
    c = load()
    if argv[1:] == ["--check"]:
        errs = check(c)
        for e in errs:
            print(f"::error::{e}" if "GITHUB_ACTIONS" in __import__("os").environ else e)
        if errs:
            print(f"hci-config: {len(errs)} ecart(s) dans {CONF}", file=sys.stderr)
            return 1
        print(f"hci-config: {CONF} coherent")
        return 0
    if argv[1:2] == ["get"] and len(argv) == 3:
        v = c.get(argv[2])
        print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
    elif argv[1:] == ["version"]:
        print(read_version(c["version"]))
    elif argv[1:2] == ["want"] and len(argv) == 3:
        print(read_version(c["version"]) if argv[2] == "version" else read_version({"key": argv[2]}))
    elif argv[1:] == ["tag"]:
        print(tag(c))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
