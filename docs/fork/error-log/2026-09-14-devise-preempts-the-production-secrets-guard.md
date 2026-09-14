# Devise pre-empts `Custom::ProductionSecretsGuard`, so its SECRET_KEY_BASE branch barely fires

- **Date**: 2026-09-14
- **Phase**: Phase 0 (deployment hardening)
- **Area**: backend

## Symptom

Verifying the newly built production image on the VPS, the guard was expected to
refuse the boot and name its missing variables. It did refuse — with somebody
else's error:

```text
$ docker run --rm -e RAILS_ENV=production mesh-crm:production \
    bundle exec rails runner 'puts "BOOTED WITHOUT GUARD"'

railties-7.2.3.1/lib/rails/application/configuration.rb:521:
  Missing `secret_key_base` for 'production' environment,
  set this string with `bin/rails credentials:edit` (ArgumentError)
    from devise-4.9.4/lib/devise/secret_key_finder.rb:24 'key_exists?'
    from devise-4.9.4/lib/devise/rails.rb:41 'block in <class:Engine>'
    from railties/lib/rails/initializable.rb:32 'Initializer#run'
    from railties/lib/rails/application.rb:435 'Rails::Application#initialize!'
```

`Custom::ProductionSecretsGuard::MisconfiguredError` never appeared.

## Root cause

Ordering, not a broken guard. Devise's engine initializer calls
`secret_key_base` during `run_initializers`, and Rails raises there. The guard
runs from `config.after_initialize`, which is the *last* phase of
`Rails::Application#initialize!` — so when `SECRET_KEY_BASE` is absent entirely,
Rails aborts several phases before the guard is reached.

`after_initialize` was chosen deliberately and is still right: it is the only
point where `ActiveRecord::Encryption.config` has been populated by activerecord's
lazy `on_load(:active_record_encryption)` hook, and the only point where
autoloading a `custom/app/**` constant is safe. Moving the guard earlier to win
this race would break the check that actually matters.

## Fix

**No code change.** Nothing is unprotected — the branches divide cleanly:

| case | who refuses the boot |
| --- | --- |
| `SECRET_KEY_BASE` missing/blank | **Rails/Devise**, loudly, before the guard |
| `SECRET_KEY_BASE` = placeholder text | **the guard** — Rails accepts any non-empty string |
| any `ACTIVE_RECORD_ENCRYPTION_*` missing | **the guard** — the silent-plaintext case |

The dangerous case was always the third one, and it is the one the guard owns.
What changed is the documentation: the guard's docblock and PR #30 described it
as naming *every* missing variable at once, which holds only once
`secret_key_base` is present. Corrected in
`custom/app/services/custom/production_secrets_guard.rb`.

## Verification

⚠ **A test that omits `SECRET_KEY_BASE` does not exercise this guard** — it dies
in Devise first and proves nothing about the overlay. Supply a throwaway value so
boot gets past Devise:

```sh
docker run --rm -e RAILS_ENV=production \
  -e SECRET_KEY_BASE=testonlynotarealsecret0123456789abcdef0123456789abcdef \
  mesh-crm:production bundle exec rails runner 'puts "BOOTED WITHOUT GUARD"'
# => Custom::ProductionSecretsGuard::MisconfiguredError naming the three
#    ACTIVE_RECORD_ENCRYPTION_* keys
```

Unit coverage is unaffected — the spec injects `rails_env:` and never boots Rails,
which is exactly why it could not have caught this.

## Notes / related

- The guard itself: [2026-09-14 — Production booted happily with Active Record encryption unconfigured](./2026-09-14-production-booted-happily-with-encryption-unconfigured.md).
- **The general lesson:** a guard's unit tests can pass while its *position in the
  boot sequence* makes a branch unreachable. The spec called the object directly;
  only booting the real image in the real environment showed which error a human
  actually sees. Test the mechanism where it runs, not only where it is defined.
