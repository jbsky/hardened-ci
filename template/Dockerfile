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

FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS builder
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
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS prep

FROM scratch
COPY --from=builder /out/VERSION /VERSION
# Une image sans commande ne se cree pas (docker create), ce que font
# image-manifest.py et check-image-closure.sh : une vraie image a son init.
CMD ["/VERSION"]
