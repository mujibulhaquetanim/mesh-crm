# `/super_admin/password/new` and `/password/edit` 500 — Devise's shared partial links to an omniauth helper this app never generates

- **Date**: 2026-08-19
- **Phase**: Phase 0 (Super Admin hardening)
- **Area**: backend

## Symptom

```text
NoMethodError in Devise::Passwords#new
undefined method 'omniauth_authorize_path' for an instance of #<Class:0x...>

  <%- if devise_mapping.omniauthable? %>
    <%- resource_class.omniauth_providers.each do |provider| %>
      <%= button_to "Sign in with #{...}", omniauth_authorize_path(resource_name, provider) ... %>
```

Both HTML pages of the operator password-reset flow return 500. Found while
verifying that removing the `sign_up` route did not break any view.

## Root cause

Pre-existing, and **not** caused by the `skip: [:registrations]` change —
reproduced on pristine `develop` with the fork's routes edit and view shadow
removed.

Devise renders these pages from its own `devise/passwords/{new,edit}` templates,
which `render "devise/shared/links"`. That partial gates the omniauth button on
`devise_mapping.omniauthable?`, which reads the **model's** devise modules —
`SuperAdmin < User` declares `:omniauthable`, so it is always true. But Chatwoot
registers providers through `OmniAuth::Builder` middleware
(`config/initializers/omniauth.rb`), never through
`Devise.setup { config.omniauth ... }`, so Devise never generates the
`omniauth_authorize_path` helper. Module says yes, route says nothing exists.
Nothing about this is environment-specific.

The registerable branch of the same partial has the identical shape, which is why
`skip: [:registrations]` needed
`custom/app/views/devise/shared/_links.html.erb` as a companion — it keys that
branch off `devise_mapping.used_routes` instead of the model's modules.

## Fix

**Fixed 2026-08-20** (this entry originally recorded it as a deliberate
non-fix; that call was reconsidered once the endpoints were actually probed).

`custom/app/views/devise/shared/_links.html.erb` — the provider list is
intersected with `Devise.omniauth_configs.keys`, so a provider is linked only
when Devise actually generated its route:

```erb
<%- (resource_class.omniauth_providers & Devise.omniauth_configs.keys).each do |provider| %>
```

**Why the original reasoning was wrong.** It assumed repairing the page would
"turn a dead page into a live, unauthenticated reset form". It does not — the
form was never what made the flow reachable. Measured on the running prod-mode
stack:

```text
POST /super_admin/password  (no form, no session, just a CSRF token) -> 302
GET  /super_admin/password/new                                       -> 500
```

The POST/PUT endpoints never load this partial and were live the entire time.
So the 500 was a broken page in front of an open door: it blocked the
legitimate operator's browser and nothing else. Leaving it was not a
fail-closed posture, it was a fail-*confusing* one — and a fragile one, since
anyone later moving these providers into `Devise.setup` would have silently
turned the page back on without review.

Note the fix could **not** reuse the registerable branch's
`devise_mapping.used_routes` treatment, contrary to what this entry first
suggested: `used_routes` DOES include `:omniauth_callback` for this mapping, so
that predicate is true while the helper is still undefined.
`Devise.omniauth_configs` is what actually decides whether Devise built it.

Docs corrected: `docs/fork/SUPER_ADMIN.md` §4.0 no longer says host access is
the only recovery path.

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -lc 'bundle install >/dev/null && bundle exec rspec \
    spec/custom/controllers/devise_overrides/ spec/custom/routing'
```

→ 11 examples, 0 failures. Proved red: reverting the intersection to
`resource_class.omniauth_providers.each` fails all 4 examples in
`super_admin_password_pages_spec.rb`.

## Notes / related

- The endpoints themselves always worked: `PUT /super_admin/password` with a
  valid token resets the password, which is what
  `spec/custom/controllers/devise_overrides/super_admin_passwords_guard_spec.rb`
  exercises. That fact is what made the page fix safe rather than a posture
  change — see **Fix** above.
- **Lesson:** "it currently errors" is not the same as "it is closed". Probe the
  endpoint before treating a broken page as a security boundary.
