# syntax=docker/dockerfile:1
# =====================================================================
#  <app>-hardened -- gabarit (jbsky/hardened-ci/template)
#
#  Aucune version n'est ecrite ici : versions.json est la seule source.
#  Chaque cle devient un build-arg (app -> APP_VERSION, app_sha256 ->
#  APP_SHA256, tcc_commit -> TCC_COMMIT) ; la base alpine est epinglee
#  tag@sha256 sur les FROM, et son tag est compare a .alpine.
#  scripts/versions-build-args.py --check (job lint) refuse toute valeur
#  par defaut, tout ARG sans cle, toute cle morte, tout ARG sans garde.
# =====================================================================

FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS builder
ARG APP_VERSION
# Echouer tout de suite, avec la marche a suivre, plutot que construire a vide.
RUN test -n "${APP_VERSION}" \
    || { echo "build-args requis depuis versions.json : make build, ou docker build \$(scripts/versions-build-args.py --docker) ." >&2; exit 1; }

# A remplacer : telechargement verifie (signature ou sha256 de versions.json),
# compilation durcie, cloture des dependances. Le gabarit ne fait que prouver
# que la version de versions.json arrive jusqu'a l'image.
RUN mkdir -p /out && printf '%s\n' "${APP_VERSION}" > /out/VERSION

# Stage prep : les paquets runtime qui finiront dans l'image (aucun ici). Le
# gabarit build-push le construit a part et le scanne (Trivy, SBOM attestee) :
# c'est le seul stage encore lisible par un scanner.
FROM alpine:3.24@sha256:be2656061b536c1883c4034790e21d0a09c5aaaf51968b89368a3c0371ea2c9a AS prep
SHELL ["/bin/ash", "-eo", "pipefail", "-c"]
# apk upgrade d'abord : `apk add` ne met jamais a jour un paquet deja dans la
# base (libcrypto3, musl...). Les dix depots du parc l'ont ; le gabarit ne
# l'avait pas, et c'est ce qui laissait ses CVE de base visibles meme apres
# une remontee de digest. prep n'est jamais cache (no-cache-filters) : le
# stage scanne est donc a jour quel que soit l'age du digest.
RUN apk upgrade --no-cache

# Image finale : FROM scratch, rien d'autre que ce que le service exige ; sa
# cloture de dependances est verifiee a chaque build (check-image-closure.sh).
FROM scratch
COPY --from=builder /out/VERSION /VERSION
# Une image sans commande ne se cree pas (docker create), ce que font
# image-manifest.py et check-image-closure.sh : une vraie image a son init.
CMD ["/VERSION"]
