#!/usr/bin/env python3
"""Tests de prune-keep-tags.sh -- liste de tags injectee, aucun acces registre."""
import subprocess
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "prune-keep-tags.sh"


def garde(tags, keep):
    """Rend la liste des tags conserves, dans l'ordre produit par le script."""
    out = subprocess.run(
        [str(SCRIPT), str(keep)], input="\n".join(tags) + "\n",
        capture_output=True, text=True, check=True)
    return [t for t in out.stdout.split("\n") if t]


# Les tags de jbsky/traefik-hardened tels que Docker Hub les listait le
# 2026-10-23, juste avant la publication de 3.7.16.0.
TRAEFIK = ["3.7.14", "3.7.14.0", "3.7.14.1", "3.7.14.2", "3.7.14.3",
           "3.7.16", "3.7.16.0", "latest"]


class Retention(unittest.TestCase):
    # --- le defaut constate en production --------------------------------
    def test_le_tag_court_ne_prend_pas_la_place_d_une_revision(self):
        """KEEP=6 doit garder SIX revisions, pas quatre revisions et deux
        tags courts. Le 2026-10-23 la publication de 3.7.16.0 a supprime
        3.7.14.0, qui etait l'image servie par l'ingress k3s."""
        gardes = garde(TRAEFIK, 6)
        self.assertIn("3.7.14.0", gardes)

    def test_keep_compte_les_revisions_pas_les_tags_flottants(self):
        gardes = garde(TRAEFIK, 2)
        # les deux revisions les plus recentes, plus les courts qui pointent dessus
        self.assertEqual(sorted(gardes),
                         ["3.7.14", "3.7.14.3", "3.7.16", "3.7.16.0"])

    # --- invariants ------------------------------------------------------
    def test_latest_et_instantanes_hors_du_perimetre(self):
        gardes = garde(TRAEFIK + ["auto-20261023.1"], 6)
        self.assertNotIn("latest", gardes)
        self.assertNotIn("auto-20261023.1", gardes)

    def test_un_tag_court_sans_revision_gardee_est_lache(self):
        """1.0 flotte vers 1.0.1, qui sort de la fenetre : le garder ferait
        pointer un tag vivant sur un manifeste supprime."""
        gardes = garde(["2.0", "2.0.1", "2.0.2", "1.0", "1.0.1"], 2)
        self.assertEqual(sorted(gardes), ["2.0", "2.0.1", "2.0.2"])

    def test_schema_a_deux_composants(self):
        """squid n'a longtemps publie que X.Y ; aucun tag n'est alors court."""
        gardes = garde(["7.6", "7.7", "7.8"], 2)
        self.assertEqual(sorted(gardes), ["7.7", "7.8"])

    def test_revision_unique(self):
        """Le cas GHCR ou le court, le .0 et latest partagent une version."""
        gardes = garde(["3.7.16", "3.7.16.0", "latest"], 6)
        self.assertEqual(sorted(gardes), ["3.7.16", "3.7.16.0"])

    def test_fenetre_plus_large_que_le_registre(self):
        self.assertEqual(sorted(garde(["1.0.0"], 6)), ["1.0.0"])

    def test_registre_sans_tag_semver(self):
        self.assertEqual(garde(["latest", "auto-20261023.1"], 6), [])


if __name__ == "__main__":
    unittest.main()
