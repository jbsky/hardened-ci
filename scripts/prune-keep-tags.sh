#!/usr/bin/env bash
# Decides which version tags a prune run keeps. Reads the registry's tag list
# on stdin (one per line, exactly as the registry reports it -- latest and
# auto-* snapshots included), writes the tags to keep on stdout.
#
# Shared by prune-registry-tags.sh (Docker Hub) and prune-ghcr-tags.sh
# (GHCR): the two registries must never drift apart on what "keep the last
# N" means, and the rule has to be testable without touching a registry.
# `latest` is NOT returned here -- each caller protects it its own way.
set -euo pipefail

KEEP_COUNT="${1:?usage: prune-keep-tags.sh <keep_count>   (tag list on stdin)}"

# Matches X.Y (squid's 7.6), X.Y.Z (nginx's 1.30.4) and the revisioned forms
# that carry a build counter as their last component (7.6.13, 1.30.4.2).
# Anything NOT matched here is a disposable snapshot as far as callers are
# concerned, so this range has to grow whenever the tag scheme does -- a
# 4-component tag under the old {1,2} would have been wiped on its first run.
# Sort descending via per-key "nr" -- a trailing global "-r" after explicit
# "-k ...n" keys does NOT reverse them (verified: GNU coreutils 9.7 sorted
# ascending despite -r), a well-known GNU sort pitfall.
mapfile -t SEMVER_TAGS < <(
  { grep -E '^[0-9]+(\.[0-9]+){1,3}$' || true; } \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr
)

KEEP_TAGS=("${SEMVER_TAGS[@]:0:${KEEP_COUNT}}")

# A revisioned tag (7.6.13) and the short tag that floats to it (7.6) name the
# same build, but the short one sorts below every revision of itself -- so a
# plain "newest KEEP_COUNT" deletes exactly the tag deployments pin. Keep any
# tag that is a dot-prefix of one already being kept.
for tag in "${SEMVER_TAGS[@]:${KEEP_COUNT}}"; do
  for kept in "${KEEP_TAGS[@]}"; do
    case "$kept" in "${tag}."*) KEEP_TAGS+=("$tag"); break ;; esac
  done
done

if [ "${#KEEP_TAGS[@]}" -gt 0 ]; then
  printf '%s\n' "${KEEP_TAGS[@]}"
fi
