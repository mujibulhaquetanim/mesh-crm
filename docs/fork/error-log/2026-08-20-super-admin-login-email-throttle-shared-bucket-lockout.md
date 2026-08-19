# `super_admin_login/email` throttled every operator into ONE bucket — 5 failures locked out the whole console

- **Date**: 2026-08-20
- **Phase**: Phase 4 (super admin hardening)
- **Area**: backend / security

## Symptom

No error is raised — that is the problem. The throttle silently keys every
sign-in attempt on the instance to the same bucket:

```text
# config/initializers/rack_attack.rb (upstream #3830)
email = req.params['email'].presence || ActionDispatch::Request.new(req.env).params['email'].presence
email.to_s.downcase.gsub(/\s+/, '')
#=> "" for every request, because the form posts super_admin[email]
```

Reproduced as a spec: 5 failed sign-ins against `attacker-probe@example.com`
from 5 different IPs, then one attempt by `real-operator@company.com` from a
sixth IP →

```text
expected response not to have status :too_many_requests
```

## Root cause

Devise namespaces a scope's form fields under the resource name, so
`/super_admin/sign_in` posts `super_admin[email]`, never a flat `email`. The
lookup therefore always missed, and the block returned `''` rather than `nil`.
rack_attack treats `''` as a perfectly good discriminator, so it counted all
attempts — every address, every source, including addresses that do not exist —
into a single shared counter.

The result inverts the throttle's purpose. It never limited per email, and it
turned into a lockout vector: an unauthenticated client could hold every
platform operator out of the console indefinitely at the cost of one request
every three minutes.

Pre-existing and upstream (`git log -S` → `feat: Unify user and super admin
credentials (#3830)`); present in `upstream/develop`. Not introduced by the
fork.

## Fix

`config/initializers/rack_attack.rb` — read the namespaced param and return nil
when it is absent, mirroring the fork's neighbouring
`super_admin_password/email` throttle (including its `is_a?(Hash)` guard,
because a crafted `?super_admin=x` makes the value a String):

```ruby
scoped = ActionDispatch::Request.new(req.env).params['super_admin']
email = (scoped['email'].presence if scoped.is_a?(Hash)) || req.params['email'].presence
email.to_s.downcase.gsub(/\s+/, '') if email
```

**Not a loosening.** `super_admin_login/ip` (5/5min per IP) is untouched and
remains the brute-force control; this restores the complementary per-address
axis. Documented in `docs/fork/UPSTREAM_DIFF.md` §4.1.

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -lc 'bundle install >/dev/null && bundle exec rspec spec/custom/initializers'
```

→ 14 examples, 0 failures. Proved red: restoring upstream's two lines fails
exactly the lockout example and the blank-key example (the other two pass either
way — the shared bucket still trips a per-email assertion, and the IP throttle is
unrelated).

## Prevention

⚠ This edit lives **inside** an upstream block, not beside one. An upstream
rewrite of that block will NOT produce a merge conflict — it will quietly
reinstate the bug with nothing to review. `spec/custom/initializers/` is the
only detector; re-run it after any upstream pull touching rack_attack.

More generally: a throttle keyed on a value that is always blank looks stricter
than it is on a dashboard, and is a lockout vector rather than a control. When
adding one, assert that two *different* keys land in two different buckets — not
just that the limit trips.
