# `bundle exec rspec` dies on `GemNotFound` — the `test` image is older than `Gemfile.lock`

- **Date**: 2026-08-19
- **Phase**: Phase 0 (spec runner)
- **Area**: docker / ci

## Symptom

```text
bundler: failed to load command: rubocop (/gems/ruby/3.4.0/bin/rubocop)
.../bundler/definition.rb:600:in 'Bundler::Definition#materialize':
Could not find hairtrigger-1.3.1, ruby_parser-3.22.0 in locally installed gems (Bundler::GemNotFound)
```

Same failure for `rspec`. Nothing in the working tree was wrong.

## Root cause

`docker-compose.rspec.yaml`'s `test` service has **no `build:` of its own** — it
reuses whatever `mesh-crm-rails:development` currently is (this is called out in
the file's own comment, and is the same trap as
[2026-08-17](./2026-08-17-rspec-test-image-still-pinned-to-pre-rename-tag.md)).
`hairtrigger` entered `Gemfile.lock` with the Rails 7.2 schema-dump fix
(`8d263a06a0`) **after** that image was last built, and `BUNDLE_PATH=/gems` is
baked into the image rather than living on the `bundle` volume — so the volume
cannot carry the missing gems either. The image is simply behind the lockfile
and nothing detects the drift.

## Fix

Rebuild the image (`docker compose build base`) when the lockfile moves. For a
one-off spec run without a rebuild, install into the ephemeral container in the
same invocation — the container layer is thrown away with `--rm`, so it must be
one command, not two:

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c 'bundle install --quiet && bundle exec rspec spec/custom'
```

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c 'bundle install --quiet && bundle exec rspec spec/custom'
# → 203 examples, 0 failures
```

## Notes / related

- The stale-image family: [2026-08-17](./2026-08-17-rspec-test-image-still-pinned-to-pre-rename-tag.md),
  [2026-08-06 BUNDLE_PATH](./2026-08-06-vite-and-sidekiq-lose-gems-because-bundle-path-is-not-on-the-shared-volume.md).
- `mesh-crm:production` is not a substitute: it is built with
  `BUNDLE_WITHOUT=development:test`, so it has `hairtrigger` but no `rspec`.
