# Security

## Reporting a vulnerability

Through a [private GitHub security advisory](https://github.com/jbsky/hardened-ci/security/advisories/new),
not a public issue.

## What is at stake here

This repository publishes no image. It publishes **reusable workflows and
composite actions that nine image repositories run** — with *their* token,
*their* registry credentials and *their* `packages: write` permission. A
change merged here is executed by every caller that pins the new revision, so
the blast radius of a bad commit is the whole fleet, not this repository.

That is the one property to keep in mind when reviewing a pull request here.

## How callers limit that blast radius

Every caller pins a **commit SHA**, never a moving tag:

```yaml
uses: jbsky/hardened-ci/.github/workflows/build-push.yml@436323be…  # v1.4.4
```

All nine image repositories are on that SHA today. A caller keeps running the
exact revision it reviewed until someone bumps the SHA in a pull request of
its own. `# v1.4.4` is a comment: it says which release the SHA belongs to, it
does not select it.

The shared **scripts** follow the same rule. A reusable workflow checks
`jbsky/hardened-ci` out again at `${{ job.workflow_sha }}` — the SHA of the
workflow file being executed, not `github.sha`, which would be the *caller's*
commit. Workflow and scripts are thus always the same revision, and a caller
cannot be made to run scripts it did not pin.

Secrets stay on the caller's side: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
are declared as `secrets:` inputs, signing uses the OIDC identity of the run,
and no long-lived key is stored here.

## Gates on this repository

Everything below runs on push and on pull request, except where stated.

| Gate | Workflow | Covers |
|---|---|---|
| `actionlint` | `lint.yml` | every workflow file of this repository |
| script unit tests | `test.yml` | `python3 -m unittest discover -s scripts` |
| the `versions` action, both ways | `test.yml` | a sound repository must pass, a faulty one must fail |
| shared scripts | `test.yml` | revision counter, dependency closure, image manifest, the `tools/` action |
| `cve-watch`, both ways | `test.yml` | its issue logic replayed case by case, and its detection on a vulnerable *and* a clean image |
| the real `build-push`, in PR mode | `test.yml` | `template/` instantiated, linted, built and put through the functional tests by the reusable workflow itself |
| end-to-end fixture | `fixture.yml`, **manual only** | publishes `template/` through `build-push` for real, then proves the cosign identity both ways: the right source repository must pass, another must fail |

So a change to a reusable workflow *is* executed by the CI — `build-push` runs
on the witness image in PR mode on every pull request. What no automatic gate
covers is the **publication path**: pushing tags, `cosign` signing, SBOM
attestation, registry pruning. Only `fixture` proves those, it is manual, and
it publishes `ghcr.io/jbsky/app-hardened`, which is to be deleted afterwards.
Running it is the reviewer's call.

This repository does **not** audit itself. `base-watch`, `cve-watch` and
`security-audit` here are `on: workflow_call` only — they are the blocks the
image repositories call, not schedules of this one. Nothing here is published
as an image, so there is nothing of ours to scan weekly.

## Releasing

One release per behaviour change, `vX.Y.Z`, and no caller moves on its own:
bumping the pinned SHA opens **one pull request per repository**, and each is
merged only once *its* CI is green. A release that nine repositories adopt
without nine green pipelines is a release that breaks nine repositories at
once.

## Vulnerabilities in the images

A CVE in `bind9-hardened`, `nginx-hardened`, `php-fpm-hardened`,
`varnish-hardened`, `suricata-hardened`, `squid-hardened`,
`uptime-kuma-hardened`, `haproxy-hardened` or `traefik-hardened` belongs to
that repository, not here. Each one has its own `SECURITY.md`, its own
`security-audit` issue and its own waivers.
