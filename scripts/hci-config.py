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
    hci-config.py matrix             les images du depot, pour strategy.matrix (JSON)
    hci-config.py tags               {cle: <version>.<revision>} pour toutes les images (JSON)
    hci-config.py --check            controle du fichier (voir check())

`--image <cle>` restreint `get`, `version`, `want` et `tag` a une image du
depot. Sans lui, c'est la premiere (la seule, dans un depot mono-image).

Un depot peut publier PLUSIEURS images (stack-squid : squid, c-icap, clamav).
Il les declare alors dans `images`, chacune avec sa `key`, son `dockerfile`,
son `context`, sa version et ses entrees de compteur ; `platforms`, `smoke` et
`compose_service` restent au niveau du depot, parce que le test est commun --
c'est tout l'interet : les trois images sont eprouvees ENSEMBLE, par un seul
docker-compose, AVANT que l'une d'elles soit promue.

La forme mono-image (champs `image`, `version`, `revision`... a la racine)
reste valide et se lit comme une liste d'une seule image : aucun depot
existant ne bouge.

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
# Par image. `platforms` est au niveau du depot : une seule matrice de plateformes.
PER_IMAGE = {"image": str, "version": dict, "revision": list, "probes": list}
REQUIRED = {**PER_IMAGE, "platforms": list}
DEFAULTS = {"compose_service": None, "smoke": None, "validate_on_pr": False}
KEY_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")


def load():
    try:
        c = json.loads(CONF.read_text())
    except (OSError, ValueError) as e:
        raise SystemExit(f"hci-config: {CONF} illisible : {e}")
    if "images" in c:
        if not isinstance(c["images"], list) or not c["images"]:
            raise SystemExit(f"hci-config: {CONF} : images doit etre une liste non vide")
        if not isinstance(c.get("platforms"), list):
            raise SystemExit(f"hci-config: {CONF} : champ platforms absent ou de mauvais type (list attendu)")
        vus = set()
        for n, img in enumerate(c["images"]):
            if not isinstance(img, dict):
                raise SystemExit(f"hci-config: {CONF} : images[{n}] n'est pas un objet")
            key = img.get("key")
            if not isinstance(key, str) or not KEY_RE.match(key):
                raise SystemExit(f"hci-config: {CONF} : images[{n}].key absente ou invalide "
                                 f"({key!r}) -- elle nomme des artefacts de CI, donc [a-z0-9-]")
            if key in vus:
                raise SystemExit(f"hci-config: {CONF} : images[{n}].key « {key} » en double")
            vus.add(key)
            for k, t in PER_IMAGE.items():
                if not isinstance(img.get(k), t):
                    raise SystemExit(f"hci-config: {CONF} : images[{key}] : champ {k} absent "
                                     f"ou de mauvais type ({t.__name__} attendu)")
    else:
        for k, t in REQUIRED.items():
            if not isinstance(c.get(k), t):
                raise SystemExit(f"hci-config: {CONF} : champ {k} absent ou de mauvais type ({t.__name__} attendu)")
    for k, v in DEFAULTS.items():
        c.setdefault(k, v)
    return c


def images(c):
    """Les images du depot, normalisees. Un depot mono-image en a une."""
    raw = c["images"] if "images" in c else [{**c, "key": c["image"]}]
    out = []
    for img in raw:
        d = Path(img.get("dockerfile", "Dockerfile"))
        out.append({
            "key": img["key"],
            "image": img["image"],
            "dockerfile": str(d),
            # Par defaut le repertoire du Dockerfile : « squid/Dockerfile » se
            # construit depuis « squid », « Dockerfile » depuis la racine.
            "context": img.get("context", str(d.parent) if str(d.parent) != "." else "."),
            "manifest": img.get("manifest", str(d.parent / "image.manifest")),
            "version": img["version"],
            "revision": img["revision"],
            "probes": img["probes"],
            # Le service compose qui porte cette image (facultatif). Dans un
            # depot mono-image il vient de la racine, comme avant.
            "compose_service": img.get("compose_service", c.get("compose_service")) or "",
        })
    return out


def pick(c, key=None):
    """L'image demandee (ou la premiere : la seule, dans un depot mono-image)."""
    imgs = images(c)
    if key is None:
        return imgs[0]
    for img in imgs:
        if img["key"] == key:
            return img
    raise SystemExit(f"hci-config: aucune image « {key} » (connues : "
                     f"{', '.join(i['key'] for i in imgs)})")


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


def cve_watch_images(wf):
    """La liste `images:` que l'appelant passe au gabarit cve-watch.

    Lecture texte, sans PyYAML, comme push_paths. Zero ou plusieurs lignes
    « images: » est une erreur, pas un saut : sauter rendrait ce controle vert
    sur le defaut meme qu'il cherche.
    """
    found = [l for l in Path(wf).read_text().splitlines()
             if not l.lstrip().startswith("#") and re.match(r"^\s+images:\s*\S", l)]
    if len(found) != 1:
        raise SystemExit(f"hci-config: {wf} : {len(found)} ligne(s) « images: », une seule attendue")
    raw = re.sub(r"^\s+images:\s*", "", found[0]).strip()
    if len(raw) > 1 and raw[0] in "'\"" and raw[-1] == raw[0]:
        raw = raw[1:-1]
    try:
        v = json.loads(raw)
    except ValueError as e:
        raise SystemExit(f"hci-config: {wf} : « images: {raw} » n'est pas une liste JSON ({e})")
    if not isinstance(v, list) or not v or not all(isinstance(x, str) and x for x in v):
        raise SystemExit(f"hci-config: {wf} : « images: » doit etre une liste JSON non vide de noms d'images")
    return v


def check(c):
    errors = []
    imgs = images(c)
    toutes_les_entrees = []
    for img in imgs:
        ou = f"images[{img['key']}] : " if len(imgs) > 1 else ""
        try:
            read_version(img["version"])
        except SystemExit as e:
            errors.append(f"{ou}{e}")
        ins = revision_paths(img)
        toutes_les_entrees += ins
        if not ins:
            errors.append(f"{ou}revision : aucun chemin d'entree")
            continue
        if not Path(img["dockerfile"]).exists():
            errors.append(f"{ou}dockerfile {img['dockerfile']} introuvable")
            continue
        # Le compteur d'UNE image ne doit couvrir que SES sources : sinon un
        # commit sur squid/ ferait monter la revision de clamav, qui serait
        # republiee a l'identique sous un tag neuf.
        #
        # Un COPY est relatif au CONTEXTE de build, les entrees du compteur a
        # la racine du depot : « COPY conf/ » dans squid/Dockerfile (contexte
        # squid/) designe squid/conf/. Sans cette jointure, le controle
        # reclamerait « conf/ » dans le compteur -- un chemin qui n'existe pas.
        for src in copy_sources(img["dockerfile"]):
            plein = src if img["context"] == "." else f"{img['context']}/{src}"
            if not covered(plein, ins):
                errors.append(f"{ou}{img['dockerfile']} copie {src} ({plein}), absent des "
                              f"entrees du compteur ({' '.join(ins)}) : un commit qui ne "
                              f"touche que lui ne publierait rien")
    wf = Path(".github/workflows/build-push.yml")
    if wf.exists():
        pp = push_paths(wf)
        if pp:
            for i in sorted(set(toutes_les_entrees)):
                probe = i.rstrip("/") + ("/x" if i.endswith("/") else "")
                if not any(fnmatch.fnmatch(probe, g) or probe == g for g in pp):
                    errors.append(f"entree du compteur {i} absente du filtre on.push.paths : "
                                  f"un commit qui ne touche qu'elle ne declencherait aucun build")
    # Le nom d'image de cve-watch doit etre celui que ce depot publie. Le
    # gabarit arrive avec « app-hardened » : laisse tel quel (haproxy-hardened,
    # du 2026-10-04 au 10-14), l'audit quotidien interroge une image qui
    # n'existe pas, reste VERT, et ouvre une issue « audit impossible » qui ne
    # peut jamais se fermer. Un nom errone est un defaut de configuration du
    # depot : il se voit ici, pas dans un run planifie.
    wfc = Path(".github/workflows/cve-watch.yml")
    if wfc.exists():
        expected = {i["image"] for i in imgs}
        try:
            declared = set(cve_watch_images(wfc))
        except SystemExit as e:
            errors.append(str(e))
        else:
            for n in sorted(declared - expected):
                errors.append(f"cve-watch audite {n}, que ce depot ne publie pas : "
                              f"l'audit reste vert sans rien scanner")
            for n in sorted(expected - declared):
                errors.append(f"{n} est publiee mais absente de la liste de cve-watch : "
                              f"aucune surveillance CVE sur cette image")
    for img in imgs:
        ou = f"images[{img['key']}] : " if len(imgs) > 1 else ""
        for i, pr in enumerate(img["probes"]):
            if not isinstance(pr, dict) or not pr.get("cmd") or not (pr.get("regex") or pr.get("expect")):
                errors.append(f"{ou}probes[{i}] : cmd et regex (ou expect) obligatoires")
    for pl in c["platforms"]:
        if pl not in ("linux/amd64", "linux/arm64"):
            errors.append(f"platforms : {pl} inconnu (linux/amd64, linux/arm64)")
    if "linux/amd64" not in c["platforms"]:
        errors.append("platforms : linux/amd64 obligatoire (seule plateforme testee)")
    return errors


def main(argv):
    c = load()
    argv = list(argv)
    key = None
    if "--image" in argv:
        i = argv.index("--image")
        if i + 1 >= len(argv):
            raise SystemExit("hci-config: --image attend une cle d'image")
        key = argv[i + 1]
        del argv[i:i + 2]
    img = pick(c, key)
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
        # Un champ d'image d'abord (image, dockerfile, context, manifest...),
        # sinon un champ du depot (platforms, smoke, compose_service...).
        v = img[argv[2]] if argv[2] in img else c.get(argv[2])
        print(v if isinstance(v, str) else json.dumps(v, separators=(",", ":")))
    elif argv[1:] == ["version"]:
        print(read_version(img["version"]))
    elif argv[1:2] == ["want"] and len(argv) == 3:
        print(read_version(img["version"]) if argv[2] == "version" else read_version({"key": argv[2]}))
    elif argv[1:] == ["tag"]:
        print(tag(img))
    elif argv[1:] == ["matrix"]:
        print(json.dumps(images(c), separators=(",", ":")))
    elif argv[1:] == ["tags"]:
        print(json.dumps({i["key"]: tag(i) for i in images(c)}, separators=(",", ":")))
    else:
        print(__doc__, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
