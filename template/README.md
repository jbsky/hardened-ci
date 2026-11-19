# Hardened image template

Starting point of a new `<app>-hardened` repository. It only holds what must
be true **from the first commit**; the rest (verified download, hardened
build, scanned `prep` stage, closure, manifest, signed publication) comes
afterwards, without breaking what follows.

```sh
./scripts/new-image.sh ../<app>-hardened   # from the root of hardened-ci
```

`new-image.sh` copies this template and adds the shared scripts from their
reference copy (`hardened-ci/scripts/`): the template carries no copy of them
that could drift. It does not copy this file: the new repository's README
follows the outline described in
[the hardened-ci README](../README.md#the-readme-of-an-image-repository).

## Already in place: versions.json is authoritative

- `versions.json` is the **only** place a version is written;
- the `Dockerfile` has no default value and fails at the guard when a
  build-arg is missing;
- `make build` and CI pass the build-args through
  `scripts/versions-build-args.py`;
- the `lint` job runs `--check` and its unit test, the `build` job the
  `jbsky/hardened-ci/versions` action (pinned by SHA, bumped by Dependabot).

When adding a dependency: one key in `versions.json` (`foo`, `foo_sha256`),
the matching `ARG` (`FOO_VERSION`, `FOO_SHA256`) without a value, and one more
line in the guard. `make check` tells what is missing.

The hardened-ci CI instantiates this template on every PR and checks that it
passes the check, that the check fails when a hard-coded version is injected,
that a build without arguments fails at the guard, and that the built image
carries the version from `versions.json`.
