#!/usr/bin/env bash
# Prunes old immutable version tags + auto-* snapshot tags on Docker Hub,
# keeping only the last KEEP_COUNT semver tags plus :latest. Old semver tags
# point at genuinely outdated (and eventually vulnerable) nginx builds that
# never get deleted otherwise, since every build pushes a brand new
# immutable version tag without ever retiring the previous one.
#
# Which tags survive is decided by prune-keep-tags.sh, shared with
# prune-ghcr-tags.sh so the two registries cannot drift apart on it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DOCKERHUB_USERNAME="${1:?usage: prune-registry-tags.sh <dockerhub_username> <repo> [keep_count]}"
REPO="${2:?usage: prune-registry-tags.sh <dockerhub_username> <repo> [keep_count]}"
KEEP_COUNT="${3:-3}"
DOCKERHUB_PASSWORD="${DOCKERHUB_TOKEN:?DOCKERHUB_TOKEN env var required}"

TOKEN=$(curl -fsSL -X POST "https://hub.docker.com/v2/users/login/" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"${DOCKERHUB_USERNAME}\",\"password\":\"${DOCKERHUB_PASSWORD}\"}" \
  | jq -r '.token')

TAGS_JSON=$(curl -fsSL -H "Authorization: Bearer ${TOKEN}" \
  "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${REPO}/tags?page_size=100")

ALL_TAGS=$(echo "$TAGS_JSON" | jq -r '.results[].name')

mapfile -t KEEP_TAGS < <(printf '%s\n' "$ALL_TAGS" | "$HERE/prune-keep-tags.sh" "$KEEP_COUNT")

declare -A KEPT=()
for tag in "${KEEP_TAGS[@]}"; do KEPT["$tag"]=1; done

# Same ordering as the keep list, so the log reads newest-to-oldest.
mapfile -t SEMVER_TAGS < <(
  printf '%s\n' "$ALL_TAGS" \
  | { grep -E '^[0-9]+(\.[0-9]+){1,3}$' || true; } \
  | sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr
)

DELETE_SEMVER=()
for tag in "${SEMVER_TAGS[@]}"; do
  [ -n "${KEPT[$tag]+x}" ] || DELETE_SEMVER+=("$tag")
done

# auto-* (and any other non-semver, non-latest) tags are point-in-time
# snapshots already preserved via git tags + GitHub Releases -- never meant
# for pinning, always safe to prune.
mapfile -t AUTO_TAGS < <(printf '%s\n' "$ALL_TAGS" \
  | grep -vE '^[0-9]+(\.[0-9]+){1,3}$' | grep -v '^latest$' || true)

DELETE_TAGS=("${DELETE_SEMVER[@]}" "${AUTO_TAGS[@]}")

if [ "${#DELETE_TAGS[@]}" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

for tag in "${DELETE_TAGS[@]}"; do
  echo "Deleting docker.io/${DOCKERHUB_USERNAME}/${REPO}:${tag}"
  # A concurrent run may have already deleted this exact tag -- a 404 means
  # the goal state is already reached, not a real failure.
  status=$(curl -sS -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer ${TOKEN}" \
    "https://hub.docker.com/v2/repositories/${DOCKERHUB_USERNAME}/${REPO}/tags/${tag}/")
  if [ "$status" = "404" ]; then
    echo "  (already deleted by a concurrent run, skipping)"
  elif [ "${status:0:1}" != "2" ]; then
    echo "  unexpected status ${status} deleting ${tag}" >&2
    exit 1
  fi
done

echo "Kept: ${KEEP_TAGS[*]} latest"
