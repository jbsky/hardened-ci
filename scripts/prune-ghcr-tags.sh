#!/usr/bin/env bash
# Prunes old immutable version tags + auto-* snapshot tags on GHCR, mirroring
# prune-registry-tags.sh for Docker Hub. Only ever deletes a package version
# by its OWN tag reference -- untagged versions (manifest-list children,
# sbom/provenance attestations, cosign signatures) are left alone, since
# deleting those independently of their parent risks breaking a still-live
# tagged manifest.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

OWNER="${1:?usage: prune-ghcr-tags.sh <owner> <package> [keep_count]}"
PACKAGE="${2:?usage: prune-ghcr-tags.sh <owner> <package> [keep_count]}"
KEEP_COUNT="${3:-3}"

# Packages that have accumulated many untagged versions (SBOM/provenance
# attestations, cosign signatures, old manifest-list children -- never
# pruned, since deleting them independently of their parent tag risks
# breaking a still-live manifest reference) make this paginated listing
# deep enough that GHCR intermittently 502s partway through. Confirmed on
# c-icap-hardened (196 versions, 193 untagged): retrying the whole listing
# a few times clears it, no different than a human re-running the workflow.
# gh_api_retry <any|5xx> <gh api args...> -- one retry policy for every GHCR
# call of this script (5 attempts, 5/10/15/20 s apart). Output in GH_OUT.
#   any : retry whatever the error (the paginated listing, see above);
#   5xx : retry only a 5xx, and return 44 on a 404 so the caller decides
#         (a DELETE answered 5xx may still have gone through).
# Returns 0 on success, 44 on a 404 in 5xx mode, 1 otherwise.
gh_api_retry() {
  local mode=$1 attempt
  shift
  for attempt in 1 2 3 4 5; do
    if GH_OUT=$(gh api "$@" 2>&1); then
      return 0
    fi
    if [ "$mode" = 5xx ]; then
      if [[ "$GH_OUT" == *'"status":"404"'* || "$GH_OUT" == *'(HTTP 404)'* ]]; then
        return 44
      fi
      [[ "$GH_OUT" == *'(HTTP 5'[0-9][0-9]')'* ]] || return 1
    fi
    [ "$attempt" -lt 5 ] || return 1
    echo "gh api $1 failed (attempt ${attempt}/5), retrying in $((attempt * 5))s..." >&2
    sleep "$((attempt * 5))"
  done
}

if ! gh_api_retry any "/users/${OWNER}/packages/container/${PACKAGE}/versions" --paginate; then
  echo "$GH_OUT" >&2
  exit 1
fi
VERSIONS_JSON=$GH_OUT

# GHCR groups every tag pointing at the same digest into ONE version object.
# A single build push (latest + <version> + auto-YYYYMMDD.N, all one digest)
# lands as one version carrying all three tags; a cosign signature or SLSA
# attestation lands as its own version carrying just its own "sha256-..."
# tag. Any classification that looks at only one tag per version (e.g.
# tags[0]) can misclassify the whole version -- confirmed live: nginx-waf-
# hardened's GHCR "latest" was wiped entirely because the version's first
# listed tag happened to be that run's auto-* tag, and every repo's cosign
# signature was deleted every single build because "sha256-...sig"/".att"
# tags matched no protected pattern. Fix: inspect the FULL tag set of a
# version and protect it if ANY tag on it deserves protection.

# Which semver tags survive is decided by prune-keep-tags.sh, shared with
# prune-registry-tags.sh so Docker Hub and GHCR cannot drift apart on it.
mapfile -t KEEP_LIST < <(echo "$VERSIONS_JSON" \
  | jq -r '.[].metadata.container.tags[]?' \
  | "$HERE/prune-keep-tags.sh" "$KEEP_COUNT")

declare -A KEEP_SEMVER=()
for tag in "${KEEP_LIST[@]}"; do KEEP_SEMVER["$tag"]=1; done

mapfile -t TAGGED < <(echo "$VERSIONS_JSON" \
  | jq -r '.[] | select(.metadata.container.tags | length > 0) | "\(.id)\t" + (.metadata.container.tags | join(","))')

DELETE_IDS=()
for entry in "${TAGGED[@]}"; do
  id="${entry%%$'\t'*}"
  tags_csv="${entry#*$'\t'}"
  IFS=',' read -ra tags <<< "$tags_csv"

  protect=false
  for tag in "${tags[@]}"; do
    if [ "$tag" = "latest" ]; then
      protect=true
      break
    fi
    # Cosign signatures/attestations/SBOMs, tagged "sha256-<digest>.<suffix>"
    # -- a digest-derived reference, never meant to be human-pinned, and
    # load-bearing for whatever manifest it signs. Match on prefix alone
    # rather than an enumerated suffix list (.sig/.att/.sbom today, but the
    # convention isn't a contract).
    if [[ "$tag" == sha256-* ]]; then
      protect=true
      break
    fi
    if [ -n "${KEEP_SEMVER[$tag]+x}" ]; then
      protect=true
      break
    fi
  done

  if [ "$protect" = false ]; then
    DELETE_IDS+=("$id")
  fi
done

if [ "${#DELETE_IDS[@]}" -eq 0 ]; then
  echo "Nothing to prune."
  exit 0
fi

for id in "${DELETE_IDS[@]}"; do
  echo "Deleting ghcr.io/${OWNER}/${PACKAGE} version id ${id}"
  # A concurrent run (e.g. several dependabot PRs merged close together, each
  # triggering its own build+cleanup) may have already deleted this exact
  # version -- a 404 here means the goal state is already reached, not a
  # real failure.
  #
  # A 5xx is GHCR, not us (squid-hardened, 2026-11-11, run 43024405022: one
  # 502 turned a published build red): retry it, through the same gh_api_retry as the listing. A
  # DELETE answered 5xx may still have gone through, which is why a 404 on
  # the retry counts as success. Any other error (403...) aborts at once.
  rc=0
  gh_api_retry 5xx --method DELETE "/users/${OWNER}/packages/container/${PACKAGE}/versions/${id}" || rc=$?
  case $rc in
    0) ;;
    44) echo "  (already deleted, skipping)" ;;
    *) echo "$GH_OUT" >&2; exit 1 ;;
  esac
done
