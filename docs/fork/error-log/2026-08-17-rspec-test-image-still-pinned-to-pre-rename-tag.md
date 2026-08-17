# rspec `test` service pinned to the pre-rename `chatwoot-rails:development` tag — nothing rebuilds it, so it silently drifts

- **Date**: 2026-08-17
- **Phase**: dev environment (post-upstream-sync / post-rebrand)
- **Area**: docker

## Symptom

Following `docs/fork/DEV_SETUP.md`'s documented first-time command exactly:

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml \
  run --rm test bundle exec rails db:create db:schema:load
```

failed immediately:

```text
bundler: failed to load command: rails (/gems/ruby/3.4.0/bin/rails)
.../bundler/definition.rb:600:in 'Bundler::Definition#materialize': Could not
find rails-7.2.3.1, jbuilder-2.15.1, ... in locally installed gems
(Bundler::GemNotFound)
```

Superficially identical to
[2026-07-20-rspec-test-service-loses-installed-gems.md](./2026-07-20-rspec-test-service-loses-installed-gems.md),
but that entry's `run --rm` volume-loss theory doesn't explain it: no
`bundle install` had been attempted at all yet, and `rails-7.2.3.1` is baked
into the image at build time, not installed per-run.

## Root cause

`docker-compose.rspec.yaml`'s `test` service hardcodes
`image: chatwoot-rails:development` — the **pre-rebrand** tag name. The
Meta CRM → Mesh CRM rename repointed every *other* service
(`docker-compose.yaml`'s `rails`/`sidekiq` now build/tag
`mesh-crm-rails:development`), but the rspec compose file was never updated,
so nothing in the current build graph produces `chatwoot-rails:development`
any more. It was simply the last image ever tagged with that name — frozen at
**2026-07-20** (confirmed via `docker images`), predating both the rebrand and
the `chore: upgrade Rails to 7.2.3.1 (#13437)` upstream merge that landed in
`develop` afterward. `docker compose run` doesn't rebuild an `image:`-only
service (no `build:` key), so it silently ran the stale image forever — this
is the same class of bug as
[2026-07-10-stale-containers-404-after-image-retag.md](./2026-07-10-stale-containers-404-after-image-retag.md),
just against an orphaned tag instead of a moved one.

## Fix

1. **Immediate unblock** (no repo change, since two image names pointed at
   different content): rebuild the current images and alias the old tag onto
   the new build so the `test` service picks up something current:
   ```sh
   docker compose build base
   docker compose build rails
   docker tag mesh-crm-rails:development chatwoot-rails:development
   ```
2. **Durable fix** — `docker-compose.rspec.yaml:34` now points at
   `mesh-crm-rails:development`, the tag `docker-compose.yaml`'s `rails`
   service actually (re)builds, so the two files can never diverge like this
   again.

## Verification

```sh
docker compose build base && docker compose build rails
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml \
  run --rm test bundle exec rails db:create db:schema:load
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml \
  run --rm test bundle exec rspec spec/custom
# -> 124 examples, 1 failure (pre-existing, unrelated — see Notes)
```

## Notes / related

- The one remaining rspec failure after this fix
  (`spec/custom/controllers/api/v1/accounts/agents_controller_spec.rb:49`,
  "counts only tenant seats against the cap, not platform-managed infra",
  expects `:success` but gets `402`) is **pre-existing and unrelated** to this
  entry or to the PR it was found while verifying. Reproduced identically
  (`git stash`, rerun) against unmodified `develop@799ac154` — not caused by
  the image fix or by any code change in the same PR. Not investigated
  further here; flagging so the next person doesn't re-diagnose the image
  issue chasing it.
- Rule of thumb for next time: **any file with a bare `image:` (no `build:`)
  must name a tag some other service's `build:` actually produces** — grep
  `image: chatwoot` / `image: mesh-crm` across all `docker-compose*.yaml`
  after any rename and confirm every referenced tag has a producer.
