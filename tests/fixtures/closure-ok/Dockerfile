# Image temoin COMPLETE : busybox et le chargeur musl, rien d'autre.
FROM alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6 AS src
FROM scratch
COPY --from=src /lib/ld-musl-x86_64.so.1 /lib/ld-musl-x86_64.so.1
COPY --from=src /bin/busybox /bin/busybox
CMD ["/bin/busybox", "true"]
