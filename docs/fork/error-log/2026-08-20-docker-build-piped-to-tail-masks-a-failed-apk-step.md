# `docker compose build … | tail -N` reports exit 0 on a FAILED build

- **Date**: 2026-08-20
- **Phase**: image refresh (post-audit rebuild)
- **Area**: docker / ci

## Symptom

A background `docker compose build base 2>&1 | tail -5` finished with exit
code 0 and was initially reported as a success. The image did not exist. The
next step (`docker compose build rails`) then failed trying to *pull*
`mesh-crm:development` from Docker Hub:

```text
failed to solve: mesh-crm:development: failed to resolve source metadata for
docker.io/library/mesh-crm:development: pull access denied
```

## Root cause

Two stacked causes:

1. The build itself failed transiently — `docker/Dockerfile:65`
   (`apk update && apk add … ruby-full …` in the pre-builder stage) exited 1,
   almost certainly a dl-cdn.alpinelinux.org fetch blip under WSL2. A plain
   rerun of the same build passed the step with no changes.
2. The failure was invisible because the build was piped to `tail -5`: without
   `pipefail`, the pipeline's exit code is `tail`'s, which is always 0. This is
   the same masking as agentic-str's turbo-gate incident — a pipe turns any
   left-side failure into "exit 0".

## Fix

Rerun the build with output redirected to a file (no pipe) and the exit code
echoed explicitly:

```sh
docker compose build base --progress=plain > /tmp/base-build.log 2>&1
echo "build exit: $?"
```

The rerun passed the apk step (transient confirmed) and produced
`mesh-crm:development`.

## Prevention

- Never pipe a `docker build`/`docker compose build` to `tail`/`head`/`grep`
  when its exit code is the success signal. Redirect to a file and check `$?`,
  or use `set -o pipefail`.
- After any build, verify the tag actually exists (`docker images`) before
  building anything `FROM` it.
- A `pull access denied … docker.io/library/mesh-crm` error means a *local*
  base tag is missing — the daemon fell through to Docker Hub. It is a symptom
  of the previous build not having produced the tag, not an auth problem.

## Verification

```sh
docker images | grep mesh-crm
# mesh-crm:development   a9c68cd294d6  (fresh)
# spec/custom in the rebuilt image: 224 examples, 0 failures
```

## Notes / related

- Stale/masked-image family: [2026-08-19 rspec image vs Gemfile.lock](./2026-08-19-rspec-image-stale-vs-gemfile-lock.md),
  [2026-08-17 test image pinned to pre-rename tag](./2026-08-17-rspec-test-image-still-pinned-to-pre-rename-tag.md).
