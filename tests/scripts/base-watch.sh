#!/usr/bin/env bash
# Pourquoi cette porte : base-watch pose le checkout de jbsky/hardened-ci DANS
# l'espace de travail du depot appelant (`path: .hardened-ci`), et son etape de
# commit stageait par `git add -A`. git enregistre un depot imbrique comme un
# gitlink : les depots du parc ont recu un `.hardened-ci` en mode 160000 sans
# aucune entree .gitmodules, d'ou le « fatal: No url found for submodule path
# '.hardened-ci' » (exit 128) a la fin de chaque run, et un clone dont le
# sous-module ne peut pas s'initialiser.
#
# Deux temps : la mecanique (git add -A avale le depot imbrique, un staging par
# chemins ne l'avale pas), puis la regle sur les workflows livres (celui qui
# pose un checkout dans l'espace de travail ne commit que des chemins nommes).
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok   $*"; }
ko() { echo "FAIL $*"; fail=1; }

# --- 1. la mecanique, sur un depot jetable ---
git init -q "$T/depot"
cd "$T/depot"
git config user.email t@t
git config user.name t
echo "FROM alpine:3.24@sha256:aaa" > Dockerfile
git add Dockerfile
git commit -qm initial
# ce que fait actions/checkout avec `path: .hardened-ci` : un depot a part
# entiere, avec un commit extrait -- un depot vide, lui, fait echouer git add
# sur « n'a pas de commit extrait », et ne prouverait donc rien.
git init -q .hardened-ci
git -C .hardened-ci config user.email t@t
git -C .hardened-ci config user.name t
git -C .hardened-ci commit -q --allow-empty -m gabarit
echo "FROM alpine:3.24@sha256:bbb" > Dockerfile

git -c advice.addEmbeddedRepo=false add -A
if git ls-files --stage -- .hardened-ci | grep -q '^160000'; then
  ok "git add -A avale le depot imbrique en gitlink (le defaut qu'on interdit)"
else
  ko "git add -A n'a pas stage .hardened-ci : la mecanique a change, revoir cette porte"
fi
git reset -q

printf 'Dockerfile\n' > "$T/fichiers.txt"
xargs -r -a "$T/fichiers.txt" git add --
staged=$(git diff --cached --name-only)
if [ "$staged" = "Dockerfile" ]; then
  ok "le staging par chemins ne prend que le fichier reecrit"
else
  ko "staging par chemins inattendu : [$staged]"
fi

# --- 2. la regle, sur les workflows livres ---
cd "$R"
vus=0
for wf in .github/workflows/*.yml; do
  grep -q 'path: \.hardened-ci' "$wf" || continue
  vus=$((vus + 1))
  if grep -qE '^[[:space:]]*git add (-A|\.)[[:space:]]*$' "$wf"; then
    ko "$(basename "$wf") : checkout dans l'espace de travail ET git add -A -- le gitlink partirait dans le commit"
  else
    ok "$(basename "$wf") : pas de git add -A"
  fi
done
if [ "$vus" -eq 0 ]; then
  ko "aucun workflow ne pose 'path: .hardened-ci' : la porte ne regarde plus rien"
fi

exit $fail
