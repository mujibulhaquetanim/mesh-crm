# Production booted happily with Active Record encryption unconfigured — and a naive guard would have broken `docker build` instead

- **Date**: 2026-09-14
- **Phase**: Phase 0 (deployment hardening)
- **Area**: backend / docker

## Symptom

No error. That is the entire problem.

`Chatwoot.encryption_configured?` (`config/application.rb:107-114`) gates
`encrypts` on every Instagram / Facebook / Telegram / Twilio access token,
webhook secret and integration hook token — but nothing ever **called** it at
boot. Start the fork in production with the three `ACTIVE_RECORD_ENCRYPTION_*`
keys unset and:

```text
$ docker compose -f docker-compose.prod.yaml up -d
$ docker compose -f docker-compose.prod.yaml ps
rails   Up 30 seconds (healthy)
```

…a healthy container, a working inbox, and every channel credential written in
the clear. `docker-compose.prod.yaml:60`'s `:?` guard cannot see these: it is
interpolation-time, so it only protects the interpolated `CRM_*` names.
`SECRET_KEY_BASE` and the three keys arrive through `env_file:`, which no guard
inspects, and Rails treats all four as optional.

## Root cause

Two separate gaps, and the second only appeared while fixing the first.

1. **Nothing on the production path checked.** `scripts/setup/doctor.sh:348-359`
   in the platform repo checks exactly these four, but it reads
   `$REPO_ROOT/../mesh-crm/.env` — a local-dev sibling checkout. On the box the
   fork lives at `/srv/mesh-crm` with no platform repo beside it, and neither
   `release.sh` nor `deploy.yml` invokes it. The only check ran nowhere near
   production.

2. **The obvious guard breaks the image build, not the bad boot.**
   `docker/Dockerfile:84` runs `rake assets:precompile` with
   `RAILS_ENV=production` inside the build, where no real secret exists. Any
   check of the form "production + missing keys ⇒ raise" fails `docker build`
   — so the failure lands on the deploy pipeline rather than on the
   misconfiguration it was written to catch.

Also worth knowing, because it makes a guard fail for the wrong reason: the bare
readers on `ActiveRecord::Encryption::Config` **raise** rather than returning
nil.

```text
ActiveRecord::Encryption::Errors::Configuration:
  Missing Active Record encryption credential: active_record_encryption.primary_key
```

`config.primary_key` raises; `config.has_primary_key?` returns `.presence`
(activerecord-7.2.3.1 `encryption/config.rb:36-45`). Only the predicate is safe
to test with, and it treats a blank string as unset — which is what a half-filled
`.env` actually leaves behind.

## Fix

- `custom/app/services/custom/production_secrets_guard.rb` — new. Raises
  `MisconfiguredError` naming every missing variable at once, with the commands
  that generate them. Reads the **`has_*?` predicates on
  `ActiveRecord::Encryption.config`** — the object `encrypts` actually consumes
  — not a second hand-written copy of the three ENV names. `application.rb`
  assigns that config inside `if ENV[PRIMARY_KEY].present?`, so a primary key set
  without the other two leaves a half-configured encryptor that an ENV-presence
  check would wave through.
- `config/initializers/custom_production_secrets_guard.rb` — new. Calls it from
  `after_initialize`, because `ActiveRecord::Encryption.config` is populated by a
  lazy `on_load(:active_record_encryption)` hook and because the service is
  autoloaded out of `custom/app/**`.
- `docker/Dockerfile:84` — `SECRET_KEY_BASE=precompile_placeholder` →
  `SECRET_KEY_BASE_DUMMY=1`. Rails' own signal for a build-time load
  (railties `application.rb:467-471`; the Dockerfile Rails generates uses the
  same flag), which is what lets the guard tell a build from a boot. **This half
  is not optional — without it the guard fails `docker build`.**

## Verification

Unit:

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml \
  run --rm test bundle exec rspec spec/custom/services/production_secrets_guard_spec.rb
# 11 examples, 0 failures
```

Against a real production boot — the part that matters, since a guard that has
never actually refused anything may be checking nothing. All three were run:

```sh
# 1. refuses, and names the three keys
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm \
  -e RAILS_ENV=production \
  -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY= \
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY= \
  -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT= \
  test bundle exec rails runner 'puts "BOOTED"'
# => Custom::ProductionSecretsGuard::MisconfiguredError, listing all three

# 2. boots when they are set
docker compose ... run --rm -e RAILS_ENV=production \
  test bundle exec rails runner 'puts Chatwoot.encryption_configured?'
# => true

# 3. the build-time load still succeeds
docker compose ... run --rm -e RAILS_ENV=production -e SECRET_KEY_BASE_DUMMY=1 \
  -e SECRET_KEY_BASE= -e ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY= \
  -e ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY= \
  -e ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT= \
  test bundle exec rails runner 'puts "BUILD-TIME LOAD OK"'
# => BUILD-TIME LOAD OK
```

⚠ Note `.env` on a dev box already sets all four, so run 1 **only proves
anything because the values are explicitly blanked**. Without the `-e VAR=`
overrides it passes vacuously.

## Notes / related

- Booting once without the keys is **not** self-healing.
  `support_unencrypted_data = true` (`application.rb:86`) keeps rows written in
  that window readable *and plaintext forever*; only new writes get encrypted.
  Every token from day one stays in the clear until its channel is reconnected by
  hand. That is why this is a boot guard and not a log warning.
- The original incident: platform repo
  `docs/troubleshooting/chatwoot-integration/119-chatwoot-plaintext-channel-tokens-encryption-unconfigured.md`.
- [2026-08-20 — `docker compose build … | tail` reports exit 0 on a FAILED build](./2026-08-20-docker-build-piped-to-tail-masks-a-failed-apk-step.md)
  recurred while verifying this: the production rebuild was wrapped as
  `docker build … > log; echo "EXIT: $?" >> log`, so the **echo's** status became
  the command's and a failed build reported success. Make the wrapper
  `rc=$?; …; exit $rc`, and read the recorded line rather than the task status.
