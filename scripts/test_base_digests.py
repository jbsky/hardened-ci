#!/usr/bin/env python3
"""Tests de base-digests.py -- resolveur injecte, aucun acces reseau."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "base_digests", Path(__file__).resolve().parent / "base-digests.py")
bd = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(bd)

OLD = "sha256:" + "a" * 64
NEW = "sha256:" + "b" * 64
INDEX = "application/vnd.oci.image.index.v1+json"


def fetcher(mapping, ctype=INDEX):
    def f(ref):
        return mapping[ref], ctype
    return f


class Cas(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.addCleanup(self.d.cleanup)

    def write(self, name, text):
        p = Path(self.d.name) / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(text)
        return str(p)

    # --- reecriture ---------------------------------------------------
    def test_reecrit_le_digest_et_garde_le_reste(self):
        f = self.write("Dockerfile", f"""FROM alpine:3.24@{OLD} AS builder
RUN true
FROM --platform=$BUILDPLATFORM golang:1.27-alpine@{OLD} AS gobuilder
FROM scratch
""")
        res = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW, "golang:1.27-alpine": NEW}))
        self.assertEqual(len(res["changed"]), 2)
        txt = Path(f).read_text()
        self.assertIn(f"FROM alpine:3.24@{NEW} AS builder", txt)
        self.assertIn(f"FROM --platform=$BUILDPLATFORM golang:1.27-alpine@{NEW} AS gobuilder", txt)
        self.assertIn("FROM scratch", txt)
        self.assertNotIn(OLD, txt)

    def test_idempotent(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{NEW} AS b\nFROM scratch\n")
        avant = Path(f).read_text()
        res = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(res["changed"], [])
        self.assertEqual(len(res["unchanged"]), 1)
        self.assertEqual(Path(f).read_text(), avant)

    def test_sans_update_ne_touche_rien(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        res = bd.run([f], fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(len(res["changed"]), 1)
        self.assertIn(OLD, Path(f).read_text())

    def test_lignes_sans_digest_ignorees(self):
        f = self.write("Dockerfile", """FROM prep AS prep-clean
FROM ${BASE_IMAGE}
FROM wordpress:${WP_VERSION} AS wp
FROM scratch
""")
        avant = Path(f).read_text()
        res = bd.run([f], update=True, fetch=fetcher({}))
        self.assertEqual((res["changed"], res["unchanged"]), ([], []))
        self.assertEqual(Path(f).read_text(), avant)

    def test_image_partagee_par_plusieurs_dockerfiles(self):
        fs = [self.write(f"{n}/Dockerfile", f"FROM alpine:3.24@{OLD} AS b\n")
              for n in ("squid", "c-icap", "clamav")]
        res = bd.run(fs, update=True, fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(len(res["changed"]), 1)              # une seule resolution
        self.assertEqual(res["changed"][0]["rewritten"], 3)   # trois fichiers reecrits
        for f in fs:
            self.assertIn(NEW, Path(f).read_text())

    def test_deux_digests_pour_un_meme_tag(self):
        """Depots derives l'un de l'autre : les deux lignes convergent."""
        autre = "sha256:" + "c" * 64
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD} AS a\nFROM alpine:3.24@{autre} AS b\n")
        res = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(len(res["changed"]), 2)
        self.assertEqual(Path(f).read_text().count(NEW), 2)

    # --- erreurs, jamais de saut silencieux ---------------------------
    def test_digest_invalide_refuse(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        with self.assertRaises(SystemExit) as e:
            bd.run([f], update=True, fetch=fetcher({"alpine:3.24": "sha256:court"}))
        self.assertIn("invalide", str(e.exception))
        self.assertIn(OLD, Path(f).read_text())

    def test_manifeste_mono_arch_refuse(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        with self.assertRaises(SystemExit) as e:
            bd.run([f], update=True, fetch=fetcher(
                {"alpine:3.24": NEW}, "application/vnd.oci.image.manifest.v1+json"))
        self.assertIn("arm64", str(e.exception))

    def test_index_avec_parametres_accepte(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        res = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW}, INDEX + "; charset=utf-8"))
        self.assertEqual(len(res["changed"]), 1)

    def test_resolution_impossible_remonte(self):
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        def boom(ref):
            raise SystemExit("base-digests: alpine:3.24 : digest courant illisible (timeout)")
        with self.assertRaises(SystemExit):
            bd.run([f], update=True, fetch=boom)

    # --- reference ----------------------------------------------------
    def test_parse_ref(self):
        self.assertEqual(bd.parse_ref("alpine:3.24"), ("library/alpine", "3.24"))
        self.assertEqual(bd.parse_ref("alpine"), ("library/alpine", "latest"))
        self.assertEqual(bd.parse_ref("jbsky/php:8.5"), ("jbsky/php", "8.5"))
        self.assertEqual(bd.parse_ref("docker.io/library/alpine:3.24"), ("library/alpine", "3.24"))

    def test_registre_etranger_refuse(self):
        with self.assertRaises(SystemExit) as e:
            bd.parse_ref("ghcr.io/jbsky/app:1")
        self.assertIn("non gere", str(e.exception))

    def test_sujet_de_commit(self):
        self.assertEqual(
            bd.subject([{"image": "golang:1.27-alpine", "old": "sha256:" + "7" * 64,
                         "new": "sha256:" + "f" * 64}]),
            "build(base): golang:1.27-alpine 7777777 -> fffffff")

    def test_sujet_dans_le_json_du_meme_passage(self):
        """Il doit sortir du passage qui reecrit : apres coup, plus aucune derive."""
        f = self.write("Dockerfile", f"FROM alpine:3.24@{OLD}\n")
        res = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(res["subject"], f"build(base): alpine:3.24 {OLD[7:14]} -> {NEW[7:14]}")
        apres = bd.run([f], update=True, fetch=fetcher({"alpine:3.24": NEW}))
        self.assertEqual(apres["subject"], "")


if __name__ == "__main__":
    unittest.main(verbosity=2)
