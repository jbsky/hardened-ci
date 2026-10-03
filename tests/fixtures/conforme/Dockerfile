# Depot temoin conforme : versions uniquement dans versions.json.
FROM alpine:3.24@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa AS builder
ARG APP_VERSION
ARG APP_SHA256
RUN test -n "${APP_VERSION}" -a -n "${APP_SHA256}" || exit 1

FROM scratch
