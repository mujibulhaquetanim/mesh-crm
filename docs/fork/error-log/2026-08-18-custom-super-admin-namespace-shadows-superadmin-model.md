# Adding a `custom/app/controllers/custom/super_admin/` overlay silently broke `Custom::SuperAdminBootstrap`

- **Date**: 2026-08-18
- **Phase**: Super Admin MFA enforcement (SUPER_ADMIN.md §4.3 / §5 item 7)
- **Area**: backend

## Symptom

Implementing PR E (flag-gated MFA on `/super_admin/sign_in`) added the overlay
module `Custom::SuperAdmin::Devise::SessionsController`. Its own spec passed,
but the **unrelated, unmodified** `spec/custom/services/super_admin_bootstrap_spec.rb`
went from 9/9 green to 8/9 failing, with no changes to
`custom/app/services/custom/super_admin_bootstrap.rb`'s logic:

```text
NoMethodError:
  undefined method 'find_or_initialize_by' for module Custom::SuperAdmin
# ./custom/app/services/custom/super_admin_bootstrap.rb:51:in 'Custom::SuperAdminBootstrap#ensure_super_admin'
```

The new MFA-enrollment service (`Custom::SuperAdminMfaEnroll`, also new) hit the
identical error on its own first run, plus a second instance for `Mfa::ManagementService`.

## Root cause

`prepend_mod_with('SuperAdmin::Devise::SessionsController')` resolves
`Custom::SuperAdmin::Devise::SessionsController` — which requires
`Custom::SuperAdmin` to exist as an intermediate namespace. Zeitwerk creates
that namespace module eagerly as soon as the directory
`custom/app/controllers/custom/super_admin/` exists (implicit namespaces are
not lazy), and it becomes a **real constant**, unrelated to the top-level
`SuperAdmin` model.

Ruby constant lookup for a bare `SuperAdmin` inside code written as
`module Custom; class SuperAdminBootstrap; ...; end; end` walks
`Module.nesting`, which for that **nested** declaration form is
`[Custom::SuperAdminBootstrap, Custom, Object]`. Once `Custom::SuperAdmin`
exists, it's found at the `Custom` level of that search — before Ruby ever
reaches the top-level `::SuperAdmin` model. Same mechanism hit
`Mfa::ManagementService` (bare `Mfa::...` inside `Custom::*`), because
`Custom::Mfa` already existed as a namespace
(`custom/app/services/custom/mfa/management_service.rb`, pre-dating this PR) —
so this class of bug was latent for any future `Custom::Mfa::*`-adjacent
reference too, not just `SuperAdmin`.

Note the **compact** class syntax (`class Custom::Foo`) does not add this
risk: `Module.nesting` for that form is `[Custom::Foo]` only — `Custom` itself
is never in the lexical scope, so a bare `SuperAdmin`/`Mfa::...` inside a
compact-form class skips straight past the colliding namespace to the
top-level constant.

## Fix

- `custom/app/services/custom/super_admin_bootstrap.rb` (pre-existing, nested
  `module Custom; class ...` form — left as-is, out of scope to restructure):
  qualified both `SuperAdmin` references to `::SuperAdmin`.
- `custom/app/services/custom/super_admin_mfa_enroll.rb` (new): written using
  **compact** class syntax (`class Custom::SuperAdminMfaEnroll`) specifically
  to avoid this footgun going forward, plus switched `SuperAdmin.find_by` to
  `SuperAdmin.from_email` per the repo's own `UseFromEmail` rubocop cop
  (case-insensitive lookup).
- `custom/app/controllers/custom/super_admin/devise/sessions_controller.rb`
  (new): already used compact `module Custom::SuperAdmin::Devise::SessionsController`
  syntax, so its own bare `Mfa::AuthenticationService` reference was
  unaffected — verified, not assumed (see Verification).

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -lc "bundle install && bundle exec rspec \
    spec/custom/services/super_admin_bootstrap_spec.rb \
    spec/custom/services/super_admin_mfa_enroll_spec.rb \
    spec/custom/controllers/super_admin/devise/sessions_controller_spec.rb"
# -> 26 examples, 0 failures
```

## Notes / related

- General rule for this fork going forward: any new `custom/app/**/custom/<X>/`
  directory that shares a name with a top-level Chatwoot model or namespace
  (`SuperAdmin`, `Mfa`, `Account`, `User`, ...) makes `Custom::<X>` a real,
  eagerly-created constant. Prefer compact class syntax
  (`class Custom::Foo::Bar`) for anything living inside such a directory, or
  qualify the colliding reference with a leading `::`. Nested `module
  Custom; class Foo; end; end` form is the risky one — this fork's rubocop
  config already prefers compact (`Style/ClassAndModuleChildren:
  EnforcedStyle: compact`), which happens to sidestep this too, but plenty of
  pre-existing fork files (incl. `super_admin_bootstrap.rb`) predate that and
  use the nested form.
- No test caught this by construction — the bootstrap spec only failed because
  it happens to run in the same `spec/custom` suite as the new overlay. A spec
  run scoped to only the new files would have looked green while quietly
  breaking a sibling.
