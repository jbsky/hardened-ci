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
uses: jbsky/hardened-ci/.github/workflows/build-push.yml@c0be9ec…  # v1.4.3
```

A caller therefore keeps running the exact revision it reviewed until someone
bumps that SHA in a pull request of its own. `v1.4.3` is a comment: it says
which release the SHA belongs to, it does not select it.

The shared **scripts** follow the same rule. A reusable workflow checks
`jbsky/hardened-ci` out again at `${{ job.workflow_sha }}` — the SHA of the
workflow file being executed, not `github.sha`, which would be the *caller's*
commit. Workflow and scripts are thus always the same revision, and a caller
cannot be made to run scripts it did not pin.

Secrets stay on the caller's side: `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN`
are declared as `secrets:` inputs, signing uses the OIDC identity of the run,
and no long-lived key is stored here.

## Gates on this repository

| Gate | Workflow | Covers |
|---|---|---|
| `actionlint` | `lint.yml`, on push and pull request | every workflow file of this repository |
| unit tests | `test.yml`, on push and pull request | `python3 -m unittest discover -s scripts`, the `versions` action on a sound *and* a faulty repository, the `template/` image instantiated and built, and the `cve-watch` issue logic replayed case by case |
| end-to-end fixture | `fixture.yml`, **manual only** | publishes `template/` through the real `build-push`, then proves the cosign identity both ways: the right source repository must pass, another must fail |
| self-audit | `base-watch`, `cve-watch`, `security-audit` | this repository runs on its own blocks |

A reusable workflow changed without a `fixture` run is a change proved by
nothing: `actionlint` and the unit tests never execute a workflow. Since
`fixture` is manual, running it is the reviewer's call, not the CI's — and it
publishes `ghcr.io/jbsky/app-hardened`, which is to be deleted afterwards.

## Releasing

One release per behaviour change, `vX.Y.Z`, and the callers are bumped in
separate pull requests — one repository at a time, each with its own green
CI. A release that nine repositories adopt at once is a release that breaks
nine repositories at once.

## Vulnerabilities in the images

A CVE in `bind9-hardened`, `nginx-hardened`, `php-fpm-hardened`,
`varnish-hardened`, `suricata-hardened`, `squid-hardened`,
`uptime-kuma-hardened`, `haproxy-hardened` or `traefik-hardened` belongs to
that repository, not here. Each one has its own `SECURITY.md`, its own
`security-audit` issue and its own waivers.
