# `/installation/onboarding` stays an anonymous super-admin factory after `fork:super_admin:bootstrap`

- **Date**: 2026-08-19
- **Phase**: Phase 4 (super admin hardening)
- **Area**: backend / security

## Symptom

On a prod-mode instance that already had an operator (`SuperAdmin.count == 1`,
created by `rake fork:super_admin:bootstrap`), the first-run installation wizard
was still being served to unauthenticated callers — and still accepting POSTs:

```text
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/installation/onboarding
200
$ curl -s -o /dev/null -w '%{http_code}\n' -X POST http://localhost:3000/installation/onboarding
302

$ rails runner 'puts Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING).inspect'
"true"
```

Every request to `/` and `/app/login` also redirected to the wizard, so no
vendor could reach the login page.

## Root cause

`Installation::OnboardingController#create` takes **no session** and calls
`AccountBuilder.new(..., super_admin: true)` — an anonymous POST creates an
account *and* a super admin. Upstream tolerates this because the form is
upstream's only path to a first operator, and submitting it is also what
deletes the `CHATWOOT_INSTALLATION_ONBOARDING` Redis key
(`#finish_onboarding`), closing the window.

The fork replaced that premise: `Custom::SuperAdminBootstrap` provisions the
operator out-of-band, before `rails server`, and never touched the key. So the
fork's own deploy path yields an instance that already has an operator and
**still serves the anonymous wizard** — the window upstream closes on first
sign-up never closes here. Not a regression from any single commit; the gap has
existed since the bootstrap task became the documented path.

## Fix

`custom/app/services/custom/super_admin_bootstrap.rb` — new
`#close_installation_onboarding`, called from `#run` immediately after
`#ensure_super_admin`: deletes the key whenever `SuperAdmin.exists?`.

- Gated on an operator *existing*, not on this run creating one, so a re-run (or
  a run with no `SUPER_ADMIN_*` env) still closes an already-provisioned
  instance.
- Left OPEN when there is no operator at all — the upstream wizard is then the
  only way in, and revoking it would brick a fresh install.
- No env flag: an unauthenticated super-admin factory is not a posture to opt
  into.

Documented in `docs/fork/SUPER_ADMIN.md` §4.1, including the check + remediation
commands for an already-deployed instance.

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -lc 'bundle install >/dev/null && bundle exec rspec spec/custom/services/super_admin_bootstrap_spec.rb'
# → 13 examples, 0 failures
# Proved red: removing the `close_installation_onboarding` call fails exactly
# the 2 closure examples (the other 2 are over-reach guards and must stay green).
```

Live, against the prod-mode stack:

```sh
rails fork:super_admin:bootstrap   # logs "Closed the installation onboarding wizard"
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/installation/onboarding   # → 302
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:3000/app/login                 # → 200
```

## Prevention

Check any existing deployment before assuming it is safe — the key is per
instance and survives redeploys:

```sh
bundle exec rails runner 'puts Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING).inspect'
```

A non-`nil` result on an instance that already has an operator means it is
exposed right now; running the bootstrap task remediates it.
