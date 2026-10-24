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

# A tag is "floating" when another tag extends it with a dot: 7.6 next to
# 7.6.13, 3.7.14 next to 3.7.14.2. It is republished on every build of its
# series, so nothing can be pinned on it -- only the leaf tags, the immutable
# revisions, are worth a slot in the window. Letting a floating tag take one
# is what deleted traefik-hardened 3.7.14.0, the image the k3s ingress was
# serving, while its KEEP=6 window was supposedly holding six revisions.
LEAVES=()
FLOATING=()
for tag in "${SEMVER_TAGS[@]}"; do
  floating=false
  for other in "${SEMVER_TAGS[@]}"; do
    case "$other" in "${tag}."*) floating=true; break ;; esac
  done
  if [ "$floating" = true ]; then FLOATING+=("$tag"); else LEAVES+=("$tag"); fi
done

KEEP_TAGS=("${LEAVES[@]:0:${KEEP_COUNT}}")

# A floating tag then costs nothing: kept when it points into a revision that
# survives, dropped when its whole series left the window -- keeping it there
# would leave a live tag naming a manifest this very run deletes.
for tag in "${FLOATING[@]}"; do
  for kept in "${KEEP_TAGS[@]}"; do
    case "$kept" in "${tag}."*) KEEP_TAGS+=("$tag"); break ;; esac
  done
done

if [ "${#KEEP_TAGS[@]}" -gt 0 ]; then
  printf '%s\n' "${KEEP_TAGS[@]}"
fi
