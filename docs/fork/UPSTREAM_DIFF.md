# What the Mesh CRM Fork Changes vs. Upstream Chatwoot

**Baseline:** `upstream` = `github.com/chatwoot/chatwoot` (the "default repo").
**Fork:** `origin` = `github.com/mujibulhaquetanim/mesh-crm`.

This file is the single, auditable inventory of **every** change the fork makes on
top of upstream Chatwoot, so the diff stays small, reviewable, and friendly to
pulling future upstream releases. It is generated from an actual
`git` audit, not from memory — re-run the commands in
[§8](#8-how-to-reproduce-this-audit) after any upstream merge.

## 0. Verdict (the rule you asked me to keep)

> **Do not modify Chatwoot's default/core flow. Nothing default may break. Stay
> pull-request friendly with the original repo.**

**Status: held.** Concretely:

- **No core logic was rewritten.** Every touch to an OSS (`app/`, `lib/`,
  `config/`) or `enterprise/` file is one of exactly six kinds:
  1. a canonical `Foo.prepend_mod_with('Foo')` / `include_mod_with` extension
     point at the bottom of a file (the *standard Chatwoot pattern*, a no-op on
     upstream),
  2. the one-time `custom/` autoload bootstrap in `config/application.rb`,
  3. an **additive** frontend / i18n line that is **inert by default** (empty
     config, `false` prop, or a brand string that only differs when the
     installation is branded), or
  4. a **dev-environment / tooling** file that ships no runtime behavior
     (Docker compose, devcontainer, `database.yml`, `AGENTS.md`) plus two
     upstream specs whose setups the fork's guards invalidated — all
     catalogued in [§6](#6-dev-environment-tooling-and-spec-adjustments), or
  5. one of exactly **two** `config/` hardening edits on the `/super_admin`
     scope, which have no injector to hook and so could not be made from the
     overlay — catalogued in [§4.1](#41-the-two-super_admin-hardening-edits).
     Neither changes a default tenant flow, or
  6. **one** `app/views` line that swaps a serializer call site onto a
     redacting reader — the single fork edit that REMOVES fields from an
     existing response shape, and the one place the "additive only" rule below
     is knowingly broken because the fields are shared credentials. Views
     cannot be prepended, so there was no overlay to make it from —
     catalogued in [§4.2](#42-the-one-app-views-edit-inboxjsonjbuilder).
- **All real behavior lives in the `custom/` overlay** (injected via
  `prepend_mod_with`, same mechanism as `enterprise/`), plus `docs/fork/` and
  `spec/custom/`. These are fork-owned trees that upstream never touches → **zero
  merge conflicts** there.
- **Every added behavior is opt-in.** With no per-account `limits`, no
  `ENABLE_SSO_ONLY_LOGIN`, no `EXTERNAL_LOGIN_URL`, and no branding configs set,
  the app behaves byte-for-byte like stock Chatwoot (proven by the upstream +
  `spec/custom` suites staying green).
- **Frozen public contracts** (route paths, webhook event names/payloads,
  `X-Chatwoot-*` headers, existing JSON keys) are only ever **extended
  additively** — never renamed or removed. **One deliberate exception**, and it
  is a security one: four secret-shaped keys are removed from the WhatsApp
  inbox payload ([§4.2](#42-the-one-app-views-edit-inboxjsonjbuilder)).

## 1. Change map at a glance

| Layer | Location | Conflict risk on upstream pull | Nature |
| --- | --- | --- | --- |
| Fork overlay | `custom/**` | none (upstream has no `custom/`) | all real fork logic |
| Shadowed views | `custom/app/views/super_admin/devise/sessions/new.html.erb`, `custom/app/views/devise/shared/_links.html.erb` (this one shadows the **devise gem's** copy, pinned at devise 4.9.4) | **none, and that's the risk** — a full ERB copy under `custom/app/views` never produces a git conflict, so an upstream change to the *original* `app/views/super_admin/devise/sessions/new.html.erb` is silently never picked up; the shadow just keeps rendering its frozen copy. Re-diff this file against upstream's current version on every upstream pull — the pinned revision in the shadow's own header comment (`42f6621afb4e8a4ba5b6c121ca54bf46ac345fab`) is the diff anchor. | one marked `otp_attempt` field, flag-gated |
| Fork docs | `docs/fork/**` | none | this documentation + error log |
| Fork specs | `spec/custom/**` | none | fork test suite |
| Extension points | ~18 OSS/ent files, **+1–2 lines each** | trivial (append-only at EOF) | canonical `prepend_mod_with` hooks |
| Bootstrap | `config/application.rb` | trivial (adjacent to enterprise lines) | eager-load + view path for `custom/` |
| Meta webhook / secret hardening | `app/views/api/v1/models/_inbox.json.jbuilder` (1 line + comment) | **moderate** — high-churn upstream file, but the edit is one call site; re-apply it if a merge takes upstream's version ([§4.2](#42-the-one-app-views-edit-inboxjsonjbuilder)) | redacting reader for `provider_config`; the signature half needs no OSS edit at all |
| Super Admin hardening | `config/routes.rb` (1 line), `config/initializers/rack_attack.rb` (1 block) | **moderate** — both are high-churn upstream files, but each edit is a single contiguous, heavily commented hunk on the `/super_admin` scope only, so a conflict resolves by re-applying it ([§4.1](#41-the-two-super_admin-hardening-edits)) | `skip: [:registrations]` on the operator scope + a password-reset throttle |
| Frontend integration | ~13 OSS Vue/JS files | low (additive, isolated) | banner mount, quota UI, SSO redirect |
| Branding | `config/locales/en.yml` + ~16 `en*.json`/Vue literals | low (value-only swaps) | "Chatwoot" → "Mesh CRM" display copy |
| Dev env & tooling | `docker-compose.yaml`, `.devcontainer/devcontainer.json`, `config/database.yml`, `AGENTS.md` (+ net-new `docker-compose.rspec.yaml`) | **moderate** — the largest conflict surface after `db/schema.rb`; upstream edits these occasionally | Docker-only Neon/Upstash dev stack; no runtime behavior ([§6](#6-dev-environment-tooling-and-spec-adjustments)) |
| Spec adjustments | `spec/enterprise/.../accounts/agents_controller_spec.rb`, `spec/controllers/webhooks/whatsapp_controller_spec.rb` | low | setups narrowed to what the fork's guards allow — cap-exact agent creation, and an unsigned-webhook pin that now also unsets the global app secret ([§6](#6-dev-environment-tooling-and-spec-adjustments)) |

## 2. Fork-owned trees (new files — no upstream overlap)

Everything here is net-new; pulling upstream can never conflict with it.

- **`custom/` overlay** — the entire feature surface:
  - Entitlements: `custom/app/models/custom/account/plan_usage_and_limits.rb`,
    `custom/app/services/custom/entitlement_service.rb`,
    `custom/app/controllers/custom/concerns/quota_enforcement.rb`,
    `custom/app/models/custom/concerns/quota_guard.rb`.
  - Model create-guards: `custom/app/models/custom/{inbox,team,webhook,label,agent_bot,automation_rule,account_user}.rb`,
    `custom/app/models/custom/integrations/hook.rb`,
    `custom/app/models/custom/concerns/custom_attribute_definition.rb`.
    (`automation_rule.rb` carries a second, unrelated guard — reply authority;
    see `ENTITLEMENTS.md` "Reply authority".)
  - Controller guards: `custom/app/controllers/custom/api/v1/accounts/*` (teams,
    webhooks, labels, automation_rules, custom_attribute_definitions, agent_bots,
    integrations/hooks).
  - Platform-managed flag permit: `custom/app/controllers/custom/platform/api/v1/account_users_controller.rb`.
  - Platform account merge-patch: `custom/app/controllers/custom/platform/api/v1/accounts_controller.rb`
    (`custom_attributes` on update is RFC 7386-style merge-patch so the control
    plane's sparse agentic-usage writeback can't wipe Chatwoot-owned account
    attributes; `limits` keeps upstream replace semantics).
  - Agents list scoping: `custom/app/controllers/custom/api/v1/accounts/agents_controller.rb`
    (overrides `agents` → excludes `platform_managed` seats from the list, the
    create-guard count, and edit/destroy lookup, ADR-0005).
  - **Assignee-picker scoping (shipped, previously undocumented here):**
    `custom/app/controllers/custom/api/v1/accounts/assignable_agents_controller.rb`
    + `custom/app/services/custom/platform_managed_users.rb` — the SECOND
    assignee-picker path. `GET .../assignable_agents` does not call
    `Inbox#assignable_agents`, so scoping only the model (agents_controller
    above) left the visible assignment dropdown still offering the platform
    service admin. `PlatformManagedUsers` is the shared filter both surfaces
    use; deliberately not applied to `Account#administrators` globally (~12
    other consumers: mailers, ActionCable tokens, automation actions, branding
    jobs). Landed `1fb4f53ee8` (2026-07-20).
  - **The verified-identity check itself:**
    `custom/app/controllers/custom/concerns/platform_actor.rb` — every
    `platform_managed` exemption above (quota, list scoping, webhook
    visibility) keys off `platform_actor?`, which reads the ACTING identity's
    own persisted `platform_managed` flag rather than trusting a request
    parameter, so a tenant identity can never self-grant the exemption. Landed
    `2ff69f8b0f` (2026-07-05); every file above that says "gated on a verified
    service identity" means this one.
  - Limits read API + agentic-AI display:
    `custom/app/controllers/custom/enterprise/api/v1/accounts_controller.rb`
    (also re-derives `agents.consumed` from the entitlement service so the UI
    count excludes platform-managed infra).
  - Auth lockdown: `custom/app/controllers/custom/devise_overrides/sessions_controller.rb`
    (password/MFA) + `.../omniauth_callbacks_controller.rb` (Google OAuth + SAML),
    sharing `custom/app/controllers/custom/concerns/sso_only_login.rb`.
  - Super Admin bootstrap: `custom/app/services/custom/super_admin_bootstrap.rb`
    (env-driven first-boot operator + seed removal + baseline hardening; run via the
    net-new task `lib/tasks/fork/super_admin.rake` → `fork:super_admin:bootstrap`).
  - Super Admin MFA enforcement: `custom/app/controllers/custom/super_admin/devise/sessions_controller.rb`
    (`Custom::SuperAdmin::Devise::SessionsController`, flag-gated on
    `SUPER_ADMIN_ENFORCE_MFA`, hooked onto the one upstream `prepend_mod_with`
    line in §3) + `custom/app/services/custom/super_admin_mfa_enroll.rb`
    (`Custom::SuperAdminMfaEnroll`, the headless enrollment/rotate service run
    via `lib/tasks/fork/super_admin.rake` → `fork:super_admin:mfa_enroll`) +
    `custom/app/views/super_admin/devise/sessions/new.html.erb` (view-path
    shadow of the upstream sign-in form — `custom/app/views` already takes
    precedence per §4 below — adding the `otp_attempt` field only when the flag
    is on; upstream file unedited). See `docs/fork/SUPER_ADMIN.md` §4.3.
    ⚠️ **Namespace collision, handled:** this overlay makes `Custom::SuperAdmin`
    exist as a real (auto-vivified) namespace module, which shadows the
    top-level `SuperAdmin` model for any *unqualified* `SuperAdmin` reference
    lexically nested inside `module Custom; ... end` (compact `class
    Custom::Foo` definitions are unaffected — see Ruby's `Module.nesting`).
    `custom/app/services/custom/super_admin_bootstrap.rb`'s two `SuperAdmin`
    references (that file predates this PR and uses the nested `module
    Custom; class ...` form) were fixed to `::SuperAdmin` for this reason.
    `custom/app/services/custom/super_admin_mfa_enroll.rb` was written using
    **compact** class syntax (`class Custom::SuperAdminMfaEnroll`) specifically
    to sidestep the same risk for its own bare `SuperAdmin`/`Mfa::ManagementService`
    references (`Custom::Mfa` is also an existing namespace, from
    `custom/app/services/custom/mfa/`) — no `::` qualification was needed
    there as a result. **Forward-looking guidance, not a change record:** any
    future `Custom::*` file written in the *nested* `module Custom; class
    Foo; end; end` form that references `SuperAdmin`, `Mfa::*`, or any other
    name that has become a `Custom::*` namespace must qualify it with a
    leading `::`; files written in the *compact* form are safe from this
    class of bug by construction. Full writeup:
    `docs/fork/error-log/2026-08-18-custom-super-admin-namespace-shadows-superadmin-model.md`.
  - **Meta webhook signature enforcement:**
    `custom/app/controllers/custom/webhooks/whatsapp_controller.rb`
    (`Custom::Webhooks::WhatsappController`) — makes `X-Hub-Signature-256`
    mandatory on **every** `whatsapp_cloud` webhook POST as soon as the
    installation has a secret to verify with. Upstream (#14280) only requires a
    signature when the CHANNEL can prove one (an app secret in
    `provider_config`, or `source == 'embedded_signup'`), so the manual-source
    cloud inboxes this platform provisions accepted **unsigned** POSTs —
    anyone who knew a tenant's phone number could inject inbound customer
    messages that the AI agent then answered. The installation-wide
    `WHATSAPP_APP_SECRET` was already a verification *candidate* in upstream's
    `#meta_app_secrets`; it simply never made verification mandatory. The
    override is phrased as "if we can verify, we must" (`meta_app_secrets.any?`)
    rather than a new list of conditions, so a future upstream that teaches
    `#meta_app_secrets` another secret source is covered automatically.
    Untouched on purpose: the `GET` verify handshake (Meta signs deliveries,
    not subscriptions) and 360dialog (`provider == 'default'`) inboxes, which
    carry no signature at all. Wired from `config/initializers/custom_prepends.rb`
    below — **no upstream edit**. Specs:
    `spec/custom/controllers/webhooks/whatsapp_controller_spec.rb`.
  - **Meta app secret redaction:** `custom/app/models/custom/channel/whatsapp.rb`
    (`Custom::Channel::Whatsapp`) — `#provider_config_without_app_secrets` drops
    exactly `MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS` (`app_secret`,
    `app_secret_key`, `client_secret`, `api_secret`) from the inbox payload
    (call site: [§4.2](#42-the-one-app-views-edit-inboxjsonjbuilder)), reusing
    the concern's own list so the two can never disagree about what a secret is.
    A Meta app secret is **app-wide**: one tenant administrator holding it can
    forge `X-Hub-Signature-256` for every other tenant's inbox on the same Meta
    app. `api_key` is deliberately kept — it is the channel's own WABA-scoped
    send token and the dashboard reads it back.
    ⚠️ The same file carries a `before_save` that **retains** a stored app
    secret across a write that omits it, and it is load-bearing rather than
    defensive: `provider_config` is a jsonb column the inbox controller
    replaces wholesale, and the dashboard edits it read-modify-write
    (`{ ...inbox.provider_config, api_key: newKey }`), so redacting the read
    alone would make "rotate the API key" silently erase the channel's app
    secret and switch webhook verification off with no error. Sending the key
    with a blank value still clears it, so removal stays possible and explicit.
    Hooked on the `Channel::Whatsapp.prepend_mod_with('Channel::Whatsapp')` line
    upstream already ships. Specs:
    `spec/custom/models/custom/channel/whatsapp_spec.rb`,
    `spec/custom/controllers/api/v1/accounts/inbox_provider_config_redaction_spec.rb`.
    ⚠️ **Namespace note:** this overlay makes `Custom::Channel` a real
    namespace, which shadows the top-level `Channel` model for any *unqualified*
    `Channel` reference lexically nested inside `module Custom; ... end` — the
    same trap `Custom::SuperAdmin` documents above. No such file exists today
    (the three nested-form overlays reference neither `Channel` nor `Webhooks`);
    the rule for new ones is unchanged: compact form, or qualify with `::`.
  - Branding/MFA/mailers: `custom/app/services/custom/branding_setup.rb`,
    `custom/app/services/custom/mfa/management_service.rb`,
    `custom/app/mailers/custom/administrator_notifications/account_notification_mailer.rb`,
    `custom/app/views/administrator_notifications/**/*.liquid`.
- **Super Admin MFA support files:**
  - `custom/app/services/custom/super_admin_mfa.rb` (`Custom::SuperAdminMfa`) —
    the single reader of `SUPER_ADMIN_ENFORCE_MFA`, shared by the sign-in check,
    the password-reset guard, and the sign-in form's `otp_attempt` field so the
    three cannot disagree about whether enforcement is on.
  - `custom/app/services/custom/prepend_once.rb` (`Custom::PrependOnce`) —
    name-matching, idempotent `Module#prepend` for the initializer below.
  - `custom/app/views/devise/shared/_links.html.erb` — shadow of the **devise
    gem's** partial (4.9.4), required by the `skip: [:registrations]` edit in
    §4.1; see that section for why the two go together.
- **`config/initializers/custom_prepends.rb`** (net-new, previously
  undocumented here) — the fourth undocumented overlay file this pass found.
  Three classes ship with no `prepend_mod_with` hook of their own, so this
  initializer prepends onto them directly, inside `to_prepare` (so the
  prepend survives Zeitwerk reloading in development) and through
  `Custom::PrependOnce` (so that reloading does not STACK the overlay — a
  reloadable module comes back as a new object with the same name on every
  reload, which plain `prepend` cannot recognise, and the
  `Devise::PasswordsController` target below is gem-owned and never reloaded,
  so the copies would accumulate):
  - `Api::V1::Accounts::AssignableAgentsController` ← `Custom::Api::V1::Accounts::AssignableAgentsController`
    (assignee-picker scoping, §2 above).
  - `Devise::PasswordsController` ← `Custom::DeviseOverrides::SuperAdminPasswordsGuard`
    (super_admin password-reset MFA guard — see the Super Admin MFA
    enforcement bullet above and `docs/fork/SUPER_ADMIN.md` §4.3).
  - `Webhooks::WhatsappController` ← `Custom::Webhooks::WhatsappController`
    (mandatory Meta signature, §2 above). Reloadable target; entered here
    rather than as a §3 hook line precisely so the signature hardening costs
    **zero** upstream edits.

  Every other customization in this fork resolves through an upstream-supplied
  hook (§3); these are the classes where the fork had to add the hook
  itself, and it does so from a new file rather than editing an OSS one —
  zero core-file edits survives even the classes upstream didn't make
  extensible.
- **`docs/fork/`** — spec, architecture, entitlements, AI loop, provisioning,
  white-label, the external integration contract, this file, and `error-log/`.
- **`spec/custom/`** — fork test suite mirroring OSS layout.
- **`db/migrate/20260704000000_add_platform_managed_to_platform_resources.rb`** —
  net-new migration adding an **additive** `platform_managed` boolean (default
  `false`, `null: false`) to `agent_bots`, `webhooks`, `account_users` (ADR-0005).
  New timestamped migration files never conflict; `db/schema.rb` picks up the three
  columns and is regenerated on migrate.

## 3. Sanctioned OSS/enterprise extension points (one line each, no-op upstream)

Each of these adds only the canonical Chatwoot injector hook at the bottom of the
file. Upstream ships this exact pattern across the codebase, so these are the
lowest-risk possible edits.

| File | Added line | Injects |
| --- | --- | --- |
| `app/models/team.rb` | `Team.prepend_mod_with('Team')` | `Custom::Team` (quota guard) |
| `app/models/webhook.rb` | `Webhook.prepend_mod_with('Webhook')` | `Custom::Webhook` |
| `app/models/label.rb` | `Label.prepend_mod_with('Label')` | `Custom::Label` |
| `app/models/agent_bot.rb` | `AgentBot.prepend_mod_with('AgentBot')` | `Custom::AgentBot` |
| `app/models/integrations/hook.rb` | `Integrations::Hook.prepend_mod_with(...)` | `Custom::Integrations::Hook` |
| `app/controllers/api/v1/accounts/teams_controller.rb` | `...TeamsController.prepend_mod_with(...)` | quota `before_action` |
| `app/controllers/api/v1/accounts/webhooks_controller.rb` | same pattern | quota `before_action` |
| `app/controllers/api/v1/accounts/labels_controller.rb` | same pattern | quota `before_action` |
| `app/controllers/api/v1/accounts/automation_rules_controller.rb` | same pattern | quota (incl. `clone`) |
| `app/controllers/api/v1/accounts/custom_attribute_definitions_controller.rb` | same pattern | quota `before_action` |
| `app/controllers/api/v1/accounts/agent_bots_controller.rb` | same pattern | quota `before_action` |
| `app/controllers/api/v1/accounts/integrations/hooks_controller.rb` | same pattern | quota `before_action` |
| `app/controllers/platform/api/v1/account_users_controller.rb` | `...AccountUsersController.prepend_mod_with(...)` | `Custom::...AccountUsersController` (permit `platform_managed`, ADR-0005) |
| `app/controllers/platform/api/v1/accounts_controller.rb` | `...AccountsController.prepend_mod_with(...)` | `Custom::...AccountsController` (`custom_attributes` merge-patch on update) |
| `enterprise/app/controllers/enterprise/api/v1/accounts_controller.rb` | `...AccountsController.prepend_mod_with(...)` | limits endpoint + agentic-AI |
| `app/mailers/administrator_notifications/account_notification_mailer.rb` | `...AccountNotificationMailer.prepend_mod_with(...)` | branded subjects |
| `app/services/mfa/management_service.rb` | `Mfa::ManagementService.prepend_mod_with(...)` | branded TOTP issuer |
| `app/controllers/super_admin/devise/sessions_controller.rb` | `SuperAdmin::Devise::SessionsController.prepend_mod_with(...)` | `Custom::SuperAdmin::Devise::SessionsController` (flag-gated MFA enforcement, `SUPER_ADMIN_ENFORCE_MFA`; inert by default) |

> Models that already had the hook upstream — `inbox.rb`, `account_user.rb`,
> `custom_attribute_definition.rb`, `automation_rule.rb`, and
> `devise_overrides/sessions_controller.rb` — needed **no hook edit**; the fork
> just supplies the `Custom::*` module they resolve. (`account_user.rb`,
> `agent_bot.rb`, and `webhook.rb` do carry a regenerated schema-annotation
> block documenting the fork's `platform_managed` column — that annotation is
> the honest description of the fork's own migration and stays. Annotation
> refreshes must **not** spill into models the fork's migrations don't touch;
> collateral churn in `category.rb`, `platform_banner.rb`,
> `enterprise/.../captain/document.rb`, and `enterprise/.../company.rb` was
> reverted to upstream text on 2026-07-10.)

## 4. The one bootstrap edit (`config/application.rb`, +6 lines: 2 code + 4 comment)

Mirrors the existing `enterprise/` wiring for the `custom/` folder:

```ruby
config.eager_load_paths += Dir["#{Rails.root}/custom/app/**"]   # load overlay
config.paths['app/views'].unshift('custom/app/views')           # branded mailer views
```

This is the only multi-line OSS edit, and it sits directly beside the identical
enterprise lines — the intended, documented seam (see `ARCHITECTURE.md`).

### 4.1 The two `/super_admin` hardening edits

Everything else in this fork reaches upstream through an injector (§3) or a new
file (§2). These two could not: a route cannot be *removed* by appending another
`routes.draw` block, and a rack_attack throttle belongs with its siblings or the
next person to add one will not find it. Both are scoped to `/super_admin` and
neither touches a tenant flow.

| File | Edit | Why it can't live in `custom/` |
| --- | --- | --- |
| `config/routes.rb` | `skip: [:registrations]` on the one `devise_for :super_admins` line (+ a comment block) | `SuperAdmin < User` is `:registerable`, so `devise_for` routed `GET /super_admin/sign_up` and `POST /super_admin` unauthenticated, plus `DELETE /super_admin` (the signed-in operator's own account). Appended route files can only add routes, never remove one. |
| `config/initializers/rack_attack.rb` | a `super_admin_password/{ip,email}` throttle pair, directly below the existing `super_admin_login/*` pair — **plus a correction inside upstream's own `super_admin_login/email` block** (see below) | Throttles are read as a list; splitting the `/super_admin` ones across two files is how the next one gets added twice or not at all. The correction is an edit to upstream's block itself, so it has nowhere else to go. |

**The routes edit has a required companion, and it carries TWO changes.**
`skip:` removes the *routes*, but `devise_mapping.registerable?` reads the
**model's** devise modules, not the routes — so Devise's stock
`devise/shared/_links` partial goes on linking to
`new_super_admin_registration_path`, a helper the skip just deleted, and takes
`GET /super_admin/password/new` and `/super_admin/password/edit` down with a
`NoMethodError`. Those are the operator's documented recovery pages
(`SUPER_ADMIN.md` §4.0). `custom/app/views/devise/shared/_links.html.erb` shadows
that partial and keys the link off `devise_mapping.used_routes` instead — correct
for every scope, not just this one.

The same shadow also intersects the omniauth provider list with
`Devise.omniauth_configs.keys`. That fixes a **separate, pre-existing** crash on
the same two pages: `SuperAdmin < User` declares `:omniauthable` with providers,
but Chatwoot registers them as `OmniAuth::Builder` middleware rather than through
`Devise.setup`, so `omniauth_authorize_path` is never generated. Note this one
could *not* be keyed off `used_routes` — that DOES include `:omniauth_callback`
here, while the helper still does not exist. Covered by
`spec/custom/routing/super_admin_registration_routes_spec.rb` (the signup verbs
404) and `spec/custom/controllers/devise_overrides/super_admin_password_pages_spec.rb`
(both recovery pages render 200).

**The correction inside upstream's `super_admin_login/email`.** Upstream (#3830)
keys that throttle on a flat `email` param, but Devise namespaces this scope's
form fields — the form posts `super_admin[email]`. The lookup always missed and
the block returned `''`, which rack_attack accepts as a key, so every sign-in
attempt on the instance shared ONE bucket: any 5 failures, from any source,
against any address, locked **every** operator out for 15 minutes. The fork reads
`super_admin[email]` and returns nil when absent. This is not a tightening or a
loosening of brute-force protection — `super_admin_login/ip` is untouched and
still bounds attempts per IP; this restores the per-address axis upstream
intended. Covered by `spec/custom/initializers/rack_attack_super_admin_login_spec.rb`
(2 of its 4 examples fail on the upstream shape).

⚠ **On upstream pull, this one is different from every other edit in this table:**
it lives *inside* an upstream block rather than beside it, so a merge will not
conflict if upstream rewrites that block — it will silently take upstream's
version back, restoring the lockout vector with no diff to review. The spec is
the only thing that catches it. Re-run `spec/custom/initializers/` after any
upstream pull that touches rack_attack.

**On upstream pull:** both files change often upstream, but each edit is a single
contiguous hunk. Resolve a conflict by re-applying the hunk, then re-run
`spec/custom/routing/` and `spec/custom/initializers/` — they fail loudly if
either edit is lost in a merge.

### 4.2 The one `app/views` edit (`_inbox.json.jbuilder`)

| File | Edit | Why it can't live in `custom/` |
| --- | --- | --- |
| `app/views/api/v1/models/_inbox.json.jbuilder` | one line: `json.provider_config resource.channel.try(:provider_config)` → `...try(:provider_config_without_app_secrets)`, plus a four-line comment | Jbuilder templates are rendered, not autoloaded, so there is no module to prepend. The only overlay alternative is a **full copy** under `custom/app/views` (the view path is already unshifted) — and this is a high-churn upstream file, so a shadow would silently freeze it, exactly the failure mode §1 flags for the two ERB shadows. One call site is the smaller, louder edit. |

**What it changes.** That line renders a WhatsApp channel's entire
`provider_config` jsonb to any account **administrator** — the role every
vendor on this platform is provisioned into — on both `index` and `show`. Four
of its keys are what `MetaTokenVerifyConcern` verifies inbound Meta webhook
signatures with. A Meta app secret is **app-wide**, not per-inbox: whoever
holds it can forge `X-Hub-Signature-256` for every inbox on the same Meta app
— other tenants included — and can mint `appsecret_proof` for Graph calls. The
redacting reader lives in the overlay
(`Custom::Channel::Whatsapp#provider_config_without_app_secrets`, §2), so the
OSS file only names it.

**This is the one place the "additive only" contract rule (§0, and
`README.md` ground rule 5) is deliberately broken** — four keys can disappear
from an existing response. Accepted because the alternative is publishing a
shared credential, and because nothing in Chatwoot *writes* those keys: no
service, job, or frontend path sets `app_secret` / `app_secret_key` /
`client_secret` / `api_secret` on a WhatsApp channel, so they are
operator-placed values only. `api_key` — which the dashboard genuinely reads
back — is **not** redacted.

**Read and write move together.** The overlay's `before_save` retention is part
of this change, not a separate nicety: without it, an admin rotating the API
key would post the redacted config straight back and erase the stored secret.
See the §2 bullet.

**On upstream pull:** if a merge takes upstream's version of this file, the
line reverts to `try(:provider_config)` with no conflict and no visible diff —
the same silent-revert class as the `rack_attack` correction in §4.1.
`spec/custom/controllers/api/v1/accounts/inbox_provider_config_redaction_spec.rb`
is what catches it; re-run it after any upstream pull that touches
`app/views/api/v1/models/`.

## 5. Additive frontend & branding (no Ruby overlay exists for Vue/JS)

Vue/JS cannot be injected via `prepend_mod_with`, so these are direct edits — but
all are **additive and inert by default**:

- **Banner mount** — `app/javascript/dashboard/App.vue` (+3): import + register +
  `<AgenticAiLimitBanner v-if="hideOnOnboardingView" />`. The banner itself lives
  in the fork-only dir `app/javascript/dashboard/fork/AgenticAiLimitBanner.vue`
  and renders nothing unless an `agentic_ai` cap is set and reached.
  ⚠️ **Recurring class-C conflict point** (`UPSTREAM_SYNC.md` §2/§3d): upstream
  adds its own banners to these same three lists — it added
  `LowBackupCodesBanner` on 2026-08-11 and conflicted here. **Keep both sides,
  fork's line last.** Taking upstream wholesale deletes the quota banner
  silently.
- **Quota UI composable** — new files
  `app/javascript/dashboard/composables/useQuota.js` and
  `.../i18n/locale/en/quota.json` (+ one register line in `.../en/index.js`).
- **At-cap disabling** — the seven settings list pages (`agents`, `teams`,
  `labels`, `attributes`, `automation`, `agentBots`, `integrations/Webhooks`) and
  the three `IntegrationHooks*.vue` components gained `:disabled="atQuotaLimit"` +
  `:title="quotaTitle"` (props default `false`/`undefined` → identical to
  upstream until a cap is hit). `agents/Index.vue` uses `useQuota('agents')`, whose
  `consumed` now excludes platform-managed infra (backend override above).
- **SSO-expiry redirect** — `app/javascript/v3/views/login/Index.vue` (+6) reads
  `window.globalConfig?.EXTERNAL_LOGIN_URL` (populated by
  `DashboardController#app_config`) and bounces bare/expired logins to the
  external app. Empty config → no redirect.
- **`EXTERNAL_LOGIN_URL` exposure** — `app/controllers/dashboard_controller.rb`
  (+1): one additive key in `app_config`, defaulting to `''`.
- **Branding copy** — `config/locales/en.yml` (new `errors.quota.*` /
  `errors.automation_rule.*` / `errors.sso_only_login` keys + "Chatwoot"→"Mesh
  CRM" value swaps) and ~16
  frontend files (`i18n/locale/en/*.json` for dashboard/survey/widget plus a few
  Vue/JS string literals in `Code.vue`, `Widget.vue`, `ArticleSearch/Header.vue`,
  `SenderNameExamplePreview.vue`, `Mfa*.vue`, `CampaignEmptyStateContent.js`,
  `survey/views/Response.vue`). **Value-only** — every JSON key and interpolation
  variable (`{consumed}`, `{selectedChannelName}`, …) is unchanged, so upstream
  key lookups never break.

None of these alter routing, request/response shapes, or webhook payloads.

## 6. Dev environment, tooling, and spec adjustments

Non-runtime files the fork modifies for the Docker-only Neon/Upstash dev setup.
These are the **largest textual-conflict surface after `db/schema.rb`** — upstream
edits them occasionally — so they are catalogued here and should be kept as close
to upstream's text as the setup allows:

- **`docker/dockerfiles/rails.Dockerfile` / `docker/dockerfiles/vite.Dockerfile`**
  — one line each: `FROM chatwoot:development` became
  `ARG BASE_IMAGE=chatwoot:development` + `FROM ${BASE_IMAGE}`. **The default is
  upstream's original value**, so an upstream build that passes no build-arg
  behaves exactly as before and the conflict surface stays one line. Compose
  passes `BASE_IMAGE: mesh-crm:development` so the fork builds and runs its own
  tags (`mesh-crm:development`, `mesh-crm-rails:development`,
  `mesh-crm-vite:development`) instead of squatting on the `chatwoot:*` names
  used by upstream's published images.
- **`docker-compose.yaml`** — rewritten for the external-Postgres dev stack
  (Neon via `POSTGRES_*` in `.env`, no local `postgres` service, per-repo build
  targets). **Redis and mailhog are local services again** — the 2026-07-27
  entry below covers why: they were dropped in the original rewrite while
  `.env` still addressed them by their compose hostnames. `rails` and `sidekiq`
  gate on `redis: condition: service_healthy`, which matters because `sidekiq`
  declares no `entrypoint:` and therefore has no wait loop of its own. Also
  carries two env guards born from error-log entries:
  `ANNOTATERB_SKIP_ON_DB_TASKS=1` on `rails` (stops `db:migrate` from
  re-annotating OSS/enterprise models — the annotation-spill root cause) and
  `VITE_RUBY_HOST=0.0.0.0` on `vite` (dev server otherwise binds
  container-localhost and host asset requests reset). Expect conflicts when
  upstream reworks its compose file; resolve by re-applying the fork's stack on
  top of upstream's new baseline.
- **`docker-compose.rspec.yaml`** — net-new (no conflict risk): the isolated,
  tmpfs-backed test stack (see `AGENTS.md` / error-log 2026-07-02 entries for
  why specs must never run against the `rails` service).
- **`config/database.yml`** — adds `sslmode` (required by Neon) and moves
  shared connection keys into `default:`. Formatting was normalized in the
  process; if upstream edits this file, prefer taking upstream's text and
  re-adding only the `sslmode` line and env-var defaults.
- **`.devcontainer/devcontainer.json`** — ports/services adjusted to the same
  Docker-only stack.
- **`AGENTS.md`** — a fork-development section **appended** after upstream's
  content (additive; `CLAUDE.md` symlinks to it).
- **`spec/controllers/webhooks/whatsapp_controller_spec.rb`** — one upstream
  example narrowed. `skips signature validation for manual whatsapp cloud
  channels without an app secret` ran with `WHATSAPP_APP_SECRET` **set**,
  because upstream skipped verification either way. The fork requires a
  signature as soon as the installation has a secret
  ([§2](#2-fork-owned-trees-new-files--no-upstream-overlap)), so the example
  now unsets it (`env: { WHATSAPP_APP_SECRET: nil }`) and its name says "without
  any app secret". Same assertion, narrowed setup — it still pins upstream's
  behavior for a stock deployment that never configured one. Both halves are
  covered fork-side in
  `spec/custom/controllers/webhooks/whatsapp_controller_spec.rb`.
- **`spec/enterprise/controllers/api/v1/accounts/agents_controller_spec.rb`** —
  the second upstream spec edited: its setup created agents **past** the cap,
  which `Custom::Concerns::QuotaGuard` makes unreachable, so setup now fills the
  account exactly **to** the cap (same assertion, inline comment explains why).
  This is a recurring class: future upstream specs that set up over-quota state
  will need the same one-line adjustment after a sync.

## 7. Guarantee: default flows are untouched when the fork is "off"

| Default flow | Stays intact because |
| --- | --- |
| Create agent/inbox/team/webhook/… | Guard only denies when a **cap is set and reached**; unset ⇒ `ChatwootApp.max_limit` ⇒ never denies. Only a *new* 402 failure mode is added; the 201 success path is unchanged. |
| Native email/password + MFA login | `Custom::DeviseOverrides::SessionsController#create` is a straight `super` unless `ENABLE_SSO_ONLY_LOGIN` is truthy. |
| Google OAuth / SAML login | `Custom::DeviseOverrides::OmniauthCallbacksController#omniauth_success` is a straight `super` unless the same flag is on; blocked at the provider entry point before any token is minted (no OSS edit — the OSS controller already ships the `prepend_mod_with` hook). |
| `/app/login` page | Renders Chatwoot's form unless `EXTERNAL_LOGIN_URL` is set. |
| `GET /enterprise/api/v1/accounts/:id/limits` on **cloud** | Override returns `super` untouched; fork keys only appear on self-hosted (where it previously 404'd). |
| Webhooks / message API / all routes | Not modified at all — the AI loop is an external service riding stock contracts. |
| Inbound WhatsApp webhooks | Signature becomes mandatory only when the installation has a secret to verify with (`WHATSAPP_APP_SECRET`, or a per-channel one upstream already required). No config set ⇒ upstream's exact behavior. 360dialog inboxes and the `GET` verify handshake are never asked for a signature ([§2](#2-fork-owned-trees-new-files--no-upstream-overlap)). |
| Inbox API payload | Unchanged except that four secret-shaped `provider_config` keys are removed for WhatsApp channels — the one non-additive response change in the fork, and it is a credential ([§4.2](#42-the-one-app-views-edit-inboxjsonjbuilder)). `api_key` and every other key still render, and the administrator-only gating is untouched. |
| Branding | Every string falls back to "Chatwoot"/upstream default until a branding config/ENV is set. |

Proven by: `spec/custom` (83 examples, 0 failures) + upstream/enterprise suites
green with the overlay loaded, and `eslint` 0 errors.

## 8. How to reproduce this audit

```sh
git fetch upstream
BASE=$(git merge-base HEAD upstream/develop)        # true upstream divergence point
# All OSS/enterprise files the fork edits (exclude fork-owned trees):
git diff --name-only "$BASE"...HEAD | grep -vE '^(custom/|docs/fork/|spec/custom/)'
# Confirm each backend edit is an extension point / bootstrap / additive line:
git diff "$BASE"...HEAD -- app/models app/controllers app/services app/mailers config
```

Anything in that output that is **not** a `prepend_mod_with`/`include_mod_with`
line, the `application.rb` bootstrap, a documented additive line, or a
[§6](#6-dev-environment-tooling-and-spec-adjustments) dev-env/tooling file is
drift — move it into `custom/` (or revert it to upstream text) before merging.
Watch for **schema-annotation spill** in particular: `annotate` regenerating
comment blocks in models the fork's migrations don't touch is the drift class
that actually occurred (caught and reverted 2026-07-10).

## 9. Fixes applied while producing this audit (2026-07-03)

While verifying docs-vs-code, two contract-breaking bugs were found and fixed
**in a way that shrank, not grew, the OSS footprint** (full write-ups in
`error-log/`):

1. **`agentic_ai` limit key rejected by the schema** — the whole agentic-AI
   banner feature was unreachable. Fixed inside the overlay
   (`custom/app/models/custom/account/plan_usage_and_limits.rb`,
   `EXTERNAL_LIMIT_KEYS`); no OSS change.
   → `error-log/2026-07-03-agentic-ai-limit-key-rejected-by-schema.md`
2. **SSO-expiry redirect read the wrong global** — `Index.vue` used
   `window.chatwootConfig` instead of the populated `window.globalConfig`. Fixed
   at the source in `Index.vue` and **reverted** a redundant `vueapp.html.erb`
   edit, reusing the already-committed `DashboardController` wiring → one fewer
   core file touched.
   → `error-log/2026-07-03-external-login-url-not-exposed-to-frontend.md`
