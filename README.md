# hardened-ci

Shared CI building blocks for the `jbsky/*-hardened` container images
(bind9, nginx, php-fpm, varnish, suricata, squid/c-icap/clamav, uptime-kuma).

Each of those repositories used to carry its own copy of the same ~1 200 lines
of GitHub Actions and of six shared scripts, kept in sync by hand. This
repository is meant to hold them once:

| Kind | Shares | Used for |
|---|---|---|
| Reusable workflows (`on: workflow_call`) | whole jobs | `cve-watch`, `registry-cleanup`, `security-audit`, later `build-push` |
| Composite actions (`action.yml`) | steps + their scripts (via `github.action_path`) | revision counter, image manifest, dependency closure, README tags |

**Status: empty scaffold.** Nothing is consumed yet; building blocks land one
at a time, each one first adopted by a single canary repository.

## Pinning policy

Callers pin a **full commit SHA**, with the release tag as a comment, never a
branch:

```yaml
uses: jbsky/hardened-ci/.github/workflows/cve-watch.yml@<40-char sha> # v1.2.0
```

- `@main` would let one push here break every image pipeline at once.
- Dependabot (`github-actions` ecosystem) in each caller proposes the bump,
  SHA and comment together. A change here is therefore one PR in this
  repository, then one bump PR per caller.
- Roll-out order: one canary repository, read its `push` run step by step
  (not only the pull-request run), then the others.

## Secrets and permissions

Reusable workflows declare the secrets they need; callers pass them
**explicitly** (`secrets: { DOCKERHUB_TOKEN: ${{ secrets.DOCKERHUB_TOKEN }} }`),
never `secrets: inherit`. Permissions are set on the calling job; a called
workflow can only lower them.

## Signing identity

Keyless cosign signatures carry the identity of the workflow that runs the
job. Once signing moves into a reusable workflow hosted here, that identity
becomes this repository's workflow, not the image repository's. Verifiers
(README commands, `cve-watch`, `security-audit`) must accept both identities
before that move. Until then, signing stays in each image repository.

## License

Apache-2.0, like the image repositories.
