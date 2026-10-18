#!/usr/bin/env python3
"""Tests de cve-stamp.py -- une seule ligne, reecrite sur place, invisible des
autres lecteurs du Dockerfile."""
import importlib.util
import tempfile
import unittest
from pathlib import Path

_ici = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("cve_stamp", _ici / "cve-stamp.py")
cs = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(cs)

_spec_bd = importlib.util.spec_from_file_location("base_digests", _ici / "base-digests.py")
bd = importlib.util.module_from_spec(_spec_bd)
_spec_bd.loader.exec_module(bd)

DOCKERFILE = """FROM alpine:3.24@sha256:%s AS prep
RUN apk upgrade --no-cache

FROM scratch
ENTRYPOINT ["/init"]
""" % ("a" * 64)


class Cas(unittest.TestCase):
    def setUp(self):
        self.d = tempfile.TemporaryDirectory()
        self.addCleanup(self.d.cleanup)
        self.f = Path(self.d.name) / "Dockerfile"
        self.f.write_text(DOCKERFILE)

    def marque(self, cves=("CVE-2026-77214",), run="1", date="2026-10-18"):
        return cs.ligne(list(cves), run, date)

    # --- pose ----------------------------------------------------------
    def test_pose_la_ligne_en_fin_de_fichier(self):
        self.assertTrue(cs.stamp(self.f, self.marque()))
        lignes = self.f.read_text().splitlines()
        self.assertTrue(lignes[-1].startswith("# cve-rebuild "))
        self.assertIn("CVE-2026-77214", lignes[-1])
        # Le reste du Dockerfile est intact, fin de fichier comprise.
        self.assertEqual("\n".join(lignes[:-1]) + "\n", DOCKERFILE)

    def test_le_fichier_se_termine_par_une_seule_fin_de_ligne(self):
        cs.stamp(self.f, self.marque())
        texte = self.f.read_text()
        self.assertTrue(texte.endswith("\n"))
        self.assertFalse(texte.endswith("\n\n"))

    # --- reecriture ----------------------------------------------------
    def test_reecrit_sur_place_sans_empiler(self):
        cs.stamp(self.f, self.marque(run="1"))
        cs.stamp(self.f, self.marque(cves=["CVE-2027-1"], run="2", date="2027-01-09"))
        texte = self.f.read_text()
        self.assertEqual(texte.count("# cve-rebuild "), 1)
        self.assertIn("CVE-2027-1", texte)
        self.assertNotIn("CVE-2026-77214", texte)

    def test_ligne_identique_ne_change_rien(self):
        """Sans diff, pas de commit : le workflow doit pouvoir le voir."""
        m = self.marque()
        self.assertTrue(cs.stamp(self.f, m))
        self.assertFalse(cs.stamp(self.f, m))

    # --- la ligne elle-meme --------------------------------------------
    def test_liste_longue_tronquee_sur_une_ligne(self):
        m = self.marque(cves=[f"CVE-2026-{i}" for i in range(10)])
        self.assertEqual(len(m.splitlines()), 1)
        self.assertIn("(+4)", m)

    def test_cve_repetee_une_seule_fois(self):
        m = self.marque(cves=["CVE-1", "CVE-1", "CVE-2"])
        self.assertEqual(m.count("CVE-1"), 1)

    def test_invisible_des_autres_lecteurs_du_dockerfile(self):
        """base-digests.py ne doit pas prendre la marque pour un FROM."""
        cs.stamp(self.f, self.marque())
        for l in self.f.read_text().splitlines():
            if l.startswith("# cve-rebuild "):
                self.assertIsNone(bd.FROM_RE.match(l))
        self.assertEqual(list(bd.scan([str(self.f)])), ["alpine:3.24"])

    # --- garde-fous -----------------------------------------------------
    def test_jeton_fantaisiste_refuse(self):
        with self.assertRaises(SystemExit):
            cs.main([str(self.f), "--cves", "CVE-1\nRUN rm -rf /", "--run", "1"])
        self.assertNotIn("cve-rebuild", self.f.read_text())

    def test_sans_cve_refuse(self):
        with self.assertRaises(SystemExit):
            cs.main([str(self.f), "--cves", " ,, ", "--run", "1"])

    def test_dockerfile_introuvable_refuse(self):
        with self.assertRaises(SystemExit):
            cs.main([str(self.f.parent / "absent"), "--cves", "CVE-1", "--run", "1"])


if __name__ == "__main__":
    unittest.main()
