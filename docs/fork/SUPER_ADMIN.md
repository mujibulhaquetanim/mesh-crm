# Super Admin — access, management, and protection

The **Super Admin console** (`/super_admin`) is the platform operator's control
surface for the whole Chatwoot instance — separate from any tenant/vendor dashboard.
This is the most sensitive surface in the system: it can read and change **every
tenant's** data and can mint the credentials that provision everything. Treat access
to it as root access to the platform.

> **One-line rule:** Super Admin is for **you, the platform operator**, only. No
> vendor, agent, or tenant user can ever reach it. Keep it up, lock it down, and
> restrict it at the network layer.

> ⚠️ **Rotate your password now if the initial one was ever displayed or shared.**
> Any password that was printed to a terminal, a chat/log, a CI variable, or handed
> over by another person must be treated as burned — rotate it on first login. It
> takes seconds:
>
> ```bash
> docker exec \
>   -e SUPER_ADMIN_EMAIL='<your-operator-email>' \
>   -e SUPER_ADMIN_PASSWORD='<new-strong-password>' \
>   -e SUPER_ADMIN_ROTATE_PASSWORD=true \
>   chatwoot-rails-1 bundle exec rails fork:super_admin:bootstrap
> ```
>
> (Or the console form in §4.2.) The new password must satisfy Chatwoot's policy
> — upper + lower + digit + special — or the task fails loud. See §4.1 for all
> bootstrap options.

## 0. Quick access — this local Docker instance

If you just want to log in **right now** on your machine, here are the concrete
values for the running dev instance (the abstract `<chatwoot-host>` placeholders
elsewhere in this doc resolve to these locally):

| Thing | Value (this local instance) |
| --- | --- |
| **URL (browser)** | **`http://localhost:3000/super_admin`** — visiting it unauthenticated redirects to `http://localhost:3000/super_admin/sign_in`. |
| **Login email** | **`tools.meshever@gmail.com`** — the only Super Admin on this instance (`SuperAdmin` id `109`). |
| **Password** | The one you set when you created this operator. It is **not** stored in `chatwoot/.env` (no `SUPER_ADMIN_*` vars) and cannot be read back — it's a bcrypt hash in the DB. If you've forgotten it, reset it with the command below. |
| **After login** | You land on the console dashboard (`/super_admin`, `SuperAdmin::DashboardController#index`) — accounts are one click away in the nav, not the landing page (§4.0 says the same). Background jobs: **`http://localhost:3000/monitoring/sidekiq`**. Sign out: **`http://localhost:3000/super_admin/logout`**. |
| **Rails container** | `chatwoot-rails-1` (from `docker ps`). Port 3000 is published to the host; `FRONTEND_URL=http://localhost:3000`. |

> **How this operator was created:** manually on the host (not via the dev seed and
> not via the `.env` bootstrap — those vars aren't set here). There is **no**
> `john@acme.inc` seed admin on this instance, which is the secure state. Confirm
> anytime with:
> ```bash
> docker exec chatwoot-rails-1 bundle exec rails runner 'pp SuperAdmin.pluck(:id, :email)'
> # => [[109, "tools.meshever@gmail.com"]]
> ```

**Forgot / want to change the password?** There is no email reset for this scope —
reset it directly (pick a strong value: upper + lower + digit + special, or Chatwoot
rejects it):

```bash
docker exec \
  -e NEW_SUPER_ADMIN_PASSWORD='<new-strong-password>' \
  chatwoot-rails-1 bundle exec rails runner '
    sa = SuperAdmin.find_by!(email: "tools.meshever@gmail.com")
    sa.password = ENV.fetch("NEW_SUPER_ADMIN_PASSWORD"); sa.save!
    puts "password reset for #{sa.email}"'
```

Then log in at `http://localhost:3000/super_admin` with `tools.meshever@gmail.com`
and the new password.

> **Local dev only.** These values (localhost, single operator) describe your laptop
> instance. In any shared/production deployment, follow §4.1 (env-driven bootstrap)
> and §5 (network-restrict `/super_admin`, no public exposure) instead — never expose
> a password-only console like this to the internet.

## 1. What it controls (blast radius)

Routes live under `namespace :super_admin` in `config/routes.rb`, guarded by
`authenticate_super_admin!` (`app/controllers/super_admin/application_controller.rb`).
It manages, for the **entire instance**:

| Area | Route | Why it's sensitive |
| --- | --- | --- |
| **Accounts** | `super_admin/accounts` (+ `seed`, `reset_cache`) | Create/edit/**delete** any tenant account; reset caches. |
| **Users** | `super_admin/users` | Create/edit/delete any user across all tenants; **create other Super Admins** (`type: 'SuperAdmin'`). |
| **Account users** | `super_admin/account_users` | Attach/detach any user to any account with any role. |
| **Platform Apps** | `super_admin/platform_apps` | **Creates the `PLATFORM_TOKEN`** — the master provisioning credential the control plane (meta-saas/NestJS) uses to create accounts, users, SSO links, and set `accounts.limits`. Anyone here can mint or read it. |
| **Access tokens** | `super_admin/access_tokens` | View API access tokens. |
| **Installation configs** | `super_admin/installation_configs`, `app_config` | Change instance-wide settings — including `ENABLE_SSO_ONLY_LOGIN`, `ENABLE_ACCOUNT_SIGNUP`, `EXTERNAL_LOGIN_URL`, SMTP, storage. **Can disable the SSO-only lockdown.** |
| **Agent bots** | `super_admin/agent_bots` | Global agent bots. |
| **Instance status / settings** | `super_admin/instance_status`, `settings` | Health + instance settings. |
| **Sidekiq** | `/monitoring/sidekiq` (`authenticated :super_admin`) | Background-job queues (retry/kill jobs, see payloads). |

Because it owns **Platform Apps** and **installation configs**, a compromised Super
Admin can bypass every other control in this fork (mint a platform token → provision
freely; flip `ENABLE_SSO_ONLY_LOGIN` off → re-open native login). This is why the
protection below matters more than any per-tenant guard.

## 2. Who can access it (the identity model)

- Super Admin is a **separate Devise scope** — `devise_for :super_admins, path:
  'super_admin'`, model `SuperAdmin < User` (STI on `users.type = 'SuperAdmin'`).
  Authenticating to it requires a **SuperAdmin credential**, which is a different
  thing from any tenant login.
- **Vendors and agents are never Super Admins.** Every tenant user is a plain `User`
  (`type` NULL). Provisioning mints users via the Platform API
  (`POST /platform/api/v1/users`), which creates ordinary users — **no provisioning
  path sets `type: 'SuperAdmin'`**. So a tenant can never escalate into the console.
  (Regression-worthy invariant: assert no tenant-provisioned user has `type =
  'SuperAdmin'`.)
- A tenant's SSO landing (`/platform/api/v1/users/:id/login`) logs a user into the
  **dashboard** scope only; it cannot produce a `super_admin` session.

## 3. How it is protected today

| Control | Status | Where |
| --- | --- | --- |
| Separate credential model (not a tenant login) | ✅ built-in | `SuperAdmin` STI + `authenticate_super_admin!` |
| Brute-force throttle on login | ✅ built-in | `config/initializers/rack_attack.rb` — `5/5min` per IP, `5/15min` per email on `POST /super_admin/sign_in` |
| Brute-force throttle on password reset | ✅ fork | `config/initializers/rack_attack.rb` — `5/30min` per IP, `5/1h` per email on `/super_admin/password` (POST + PUT/PATCH), the scope's second login-shaped path (§4.3) |
| No tenant path into the scope | ✅ by construction | provisioning only mints `User`s |
| SSO-only lockdown covers it | ❌ **no** — separate scope | `Custom::DeviseOverrides::SessionsController` documents this explicitly |
| MFA enforced on login | ✅ behind `SUPER_ADMIN_ENFORCE_MFA` | `Custom::SuperAdmin::Devise::SessionsController` (fail-closed for un-enrolled operators; see §4.3) |
| Default seed credential in prod | ⚠️ **must be prevented** | `db/seeds.rb` seeds `john@acme.inc / Password1!` as a `SuperAdmin` — dev only |
| Self-signup on the operator scope | ✅ fork — routes removed | `SuperAdmin < User` is `:registerable`, so `devise_for` routed `GET /super_admin/sign_up`, `POST /super_admin` and `DELETE /super_admin`; `config/routes.rb` now passes `skip: [:registrations]` |
| Network restriction on `/super_admin` | ⚠️ **deployment responsibility** | not enforced by the app |

So out of the box the console is reachable at a **public password form**
(`/super_admin/sign_in`) with throttling. MFA is available — turn it on with
`SUPER_ADMIN_ENFORCE_MFA=true` after enrolling every operator (§4.3); until then,
or for operators you haven't enrolled, the password + network posture (§5)
remains the real protection.

### 3.1 What changed — why it's more secure now

The fork's first-boot bootstrap (§4.1) replaces stock Chatwoot's insecure defaults:

| | Stock Chatwoot | This fork (after `fork:super_admin:bootstrap`) |
| --- | --- | --- |
| Initial operator | hardcoded seed `john@acme.inc / Password1!` (well-known) | env-driven, strong, per-operator credential from your secrets manager |
| Weak / blank password | accepted by the seed | **fails loud** — boot errors rather than ship a weak operator |
| Default seed in prod | lingers until manually deleted | removed on boot with `SUPER_ADMIN_REMOVE_DEFAULT_SEED=true` |
| Public self-signup | on by default | off with `SUPER_ADMIN_DISABLE_SIGNUP=true` |
| Password rotation | manual console only | idempotent `SUPER_ADMIN_ROTATE_PASSWORD=true` on the same task |
| Tenant → super-admin escalation | n/a | impossible by construction (provisioning only ever mints plain `User`s) |
| Repeatability / audit | ad-hoc console commands | one idempotent task, covered by `spec/custom` |

**Still unchanged from upstream — the deployment must close these:** MFA on the
`super_admin` login path is **available but off by default**
(`SUPER_ADMIN_ENFORCE_MFA`, §4.3) and there is **no network restriction** by
default. Those are §5 items 2 and 7; treat both as required for production —
enable the flag only after every operator is enrolled (§4.3), since an
un-enrolled operator is locked out (by design — see §4.3's fail-closed note).

## 4. Managing Super Admins (operator runbook)

### 4.0 Logging in (the operator)

1. Go to **`https://<chatwoot-host>/super_admin`** — unauthenticated visits redirect
   to `/super_admin/sign_in`. This is a **separate** login from any tenant/agent
   dashboard; your tenant SSO session does **not** grant it.
2. Enter your **Super Admin** email + password (provisioned by the bootstrap §4.1, or
   created in §4.2). On success you land on the console dashboard (`/super_admin`,
   `SuperAdmin::DashboardController#index`); accounts are one click away in the nav.
   If `SUPER_ADMIN_ENFORCE_MFA` is on and you're enrolled (§4.3), also enter your
   authenticator code (or a backup code) in the same form — the sign-in is single-step.
3. Background queues are at **`/monitoring/sidekiq`** (same session). Sign out at
   **`/super_admin/logout`**.

There **is** a stock Devise self-serve password-reset flow at this scope —
`devise_for :super_admins` doesn't skip `:recoverable`, so it's routed and
mailer-dependent: `GET /super_admin/password/new` asks for the address,
`POST /super_admin/password` mails the link, `GET /super_admin/password/edit`
opens it, and `PUT/PATCH /super_admin/password` completes the reset (that last
verb is the one the guard in §4.3 intercepts). All of them are throttled — §3.

> ✅ **Fixed 2026-08-20 — these two pages render again.** They returned 500 in
> every environment before that, for the fork's whole life. Devise renders them
> from its own `devise/passwords/{new,edit}` templates, which include
> `devise/shared/_links`; that partial iterates
> `resource_class.omniauth_providers` — `[:google_oauth2, :saml]` on
> `SuperAdmin < User` — and calls `omniauth_authorize_path`, a helper this app
> never generates, because Chatwoot wires omniauth through `OmniAuth::Builder`
> middleware (`config/initializers/omniauth.rb`) instead of
> `Devise.setup { config.omniauth … }`, leaving `Devise.omniauth_configs` empty.
>
> `custom/app/views/devise/shared/_links.html.erb` now intersects the provider
> list with `Devise.omniauth_configs.keys`, so a provider is linked only when
> Devise actually built its route. Covered by
> `spec/custom/controllers/devise_overrides/super_admin_password_pages_spec.rb`
> (all 4 examples fail without the intersection).
>
> **This changed no security posture, and that is why it was safe to fix.**
> `POST`/`PUT /super_admin/password` never load this partial and were live the
> entire time — `POST` answers 302 with no session — so the 500 blocked only
> the legitimate operator's browser, never an attacker. It was a broken page in
> front of an open door, not a lock. The MFA session guard on the reset flow
> (§4.3) is untouched.
>
> Host/DB access is still the recommended path for a *full lockout*; the
> self-serve reset is now genuinely available for the ordinary case. It is **not** the
recommended rotation path — use the bootstrap or the console (§4.1 / §4.2)
instead. With `SUPER_ADMIN_ENFORCE_MFA` on, a completed reset no longer
auto-signs you in (§4.3 explains why and what guards it) — you land back on
`/super_admin/sign_in` and still need your TOTP/backup code if enrolled. If
you are fully locked out, you need host / DB access to reset it. MFA is
available but off by default (§4.3) — until you enable
`SUPER_ADMIN_ENFORCE_MFA` for every operator, **do not expose `/super_admin`
publicly** — reach it over VPN / an IP allowlist (§5).

### 4.1 First-boot bootstrap (recommended) — `fork:super_admin:bootstrap`

The fork ships an **idempotent bootstrap script** so a fresh instance comes up with a
real, env-driven operator instead of the insecure dev seed. It is safe to run on every
boot. This is the **"preloaded credential from `.env`"** mechanism: you put the
operator's email + password in `.env` (or your secrets manager), and the script reads
those vars and materialises the `SuperAdmin` row — you never type credentials into a UI.

**The script — two files, one entry point:**

- **Task (thin shim):** `lib/tasks/fork/super_admin.rake` → run with
  `bundle exec rails fork:super_admin:bootstrap`. This is what you invoke.
- **Service (the logic):** `custom/app/services/custom/super_admin_bootstrap.rb`
  (`Custom::SuperAdminBootstrap`) — fork-owned so upstream merges never touch it.
- **Tests:** `spec/custom/services/super_admin_bootstrap_spec.rb`.

**What one run does**, in order:
1. **Ensure operator** — if no `SuperAdmin` with `SUPER_ADMIN_EMAIL` exists, create it
   with `SUPER_ADMIN_PASSWORD` (confirmation skipped — nothing sends operators a
   confirmation mail to click, since they are provisioned out-of-band rather than
   self-registered; the scope's one mailer flow is the password reset in §4.0). If it already exists, leave the password **untouched** — *unless*
   `SUPER_ADMIN_ROTATE_PASSWORD=true`, in which case reset it. A weak password **fails
   loud** (raises) so the instance never boots operator-less with a bad credential.
2. **Close the installation wizard** — if the instance now has *any* `SuperAdmin`,
   delete the `CHATWOOT_INSTALLATION_ONBOARDING` Redis key. Unconditional; there is no
   env flag. See the warning below for why this is a security step and not tidying.
3. **Remove dev seed** — if `SUPER_ADMIN_REMOVE_DEFAULT_SEED=true`, delete the
   `john@acme.inc` seed admin (never the configured operator).
4. **Baseline hardening** — if `SUPER_ADMIN_DISABLE_SIGNUP=true`, set
   `ENABLE_ACCOUNT_SIGNUP=false` in `InstallationConfig` + clear the config cache.

> ⚠ **Why step 2 exists — a hole the fork opened by accident.**
>
> While the `CHATWOOT_INSTALLATION_ONBOARDING` key is set,
> `Installation::OnboardingController#create` is reachable **with no session at all**
> and calls `AccountBuilder.new(..., super_admin: true)`. An anonymous `POST
> /installation/onboarding` therefore mints a new account **and a new super admin**.
>
> Upstream is not wrong to leave it open: upstream's only route to a first operator is
> that very form, and submitting it is what deletes the key (`#finish_onboarding`).
>
> The fork changed that premise and did not close the loop. `fork:super_admin:bootstrap`
> is how this instance gets its operator, it runs before `rails server`, and it never
> touched the key — so the fork's own deploy path produced an instance that *already had
> an operator* and **still served the anonymous wizard**. The window upstream closes on
> first sign-up simply never closed here. Any deploy reachable from the internet before
> someone manually submits that form is exposed for as long as it stays unsubmitted.
>
> Gated on an operator *existing*, not on this run creating one, so a re-run — or a run
> with no `SUPER_ADMIN_*` env at all — still shuts it. When there is genuinely no
> operator the key is left alone: the upstream wizard is then the only remaining way in,
> and revoking it would brick a fresh install.
>
> **Check an existing deployment** (a non-empty result means it is exposed *now*):
> ```bash
> # on the app host / in the rails container
> bundle exec rails runner 'puts Redis::Alfred.get(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING).inspect'
> # remediate by running the bootstrap task (idempotent), or:
> bundle exec rails runner 'Redis::Alfred.delete(Redis::Alfred::CHATWOOT_INSTALLATION_ONBOARDING)'
> ```
> Then confirm `GET /installation/onboarding` returns **302**, not 200.

If `SUPER_ADMIN_EMAIL`/`SUPER_ADMIN_PASSWORD` are unset, the script logs
`… not set — skipping Super Admin bootstrap` and does nothing — which is exactly the
state on the current local instance (see §0: the operator there was created manually,
not preloaded this way).

**Environment** (put in your secrets manager / Chatwoot `.env`):

| Var | Effect |
| --- | --- |
| `SUPER_ADMIN_EMAIL` | Operator login email (required to do anything). |
| `SUPER_ADMIN_PASSWORD` | Strong password. Chatwoot enforces upper+lower+digit+special; a weak value **fails loud** (never leaves the box operator-less). |
| `SUPER_ADMIN_NAME` | Display name (default `Platform Operator`). |
| `SUPER_ADMIN_ROTATE_PASSWORD=true` | Reset an existing operator's password (off by default, so reboots don't churn it). |
| `SUPER_ADMIN_REMOVE_DEFAULT_SEED=true` | Delete the `john@acme.inc` seed admin (never the configured operator). |
| `SUPER_ADMIN_DISABLE_SIGNUP=true` | Turn off public self-signup (`ENABLE_ACCOUNT_SIGNUP=false`). |

Behavior: creates the operator only when missing; leaves an existing password alone
unless `ROTATE`; only writes configs that changed. It intentionally does **not** flip
`ENABLE_SSO_ONLY_LOGIN` (a tenant-facing control with lockout risk — enable that
separately per `../../../agentic-str/docs/operations/chatwoot-access-lockdown.md`).

**Preload a fresh operator** (first time — email not yet in the DB):

```bash
docker exec \
  -e SUPER_ADMIN_EMAIL='ops@yourcompany.com' \
  -e SUPER_ADMIN_PASSWORD='<strong-password>' \
  chatwoot-rails-1 bundle exec rails fork:super_admin:bootstrap
# → "Created Super Admin ops@yourcompany.com"
```

**Rotate an existing operator's password** — same task, but you must add
`SUPER_ADMIN_ROTATE_PASSWORD=true`, or the run is a no-op that just logs
`… already present — unchanged`:

```bash
docker exec \
  -e SUPER_ADMIN_EMAIL='ops@yourcompany.com' \
  -e SUPER_ADMIN_PASSWORD='<new-strong-password>' \
  -e SUPER_ADMIN_ROTATE_PASSWORD=true \
  chatwoot-rails-1 bundle exec rails fork:super_admin:bootstrap
# → "Rotated Super Admin password for ops@yourcompany.com"
```

Both are idempotent — re-running with the same values changes nothing. `SUPER_ADMIN_*`
must be reachable by the process: pass them inline as above (one-shot), or add them to
Chatwoot's `.env` so every boot re-asserts the operator.

**Wire it into first boot.** In your deploy (`docker-compose*.yaml` / k8s), run it
after DB prepare and before the server starts — e.g. the rails service `command`:

```yaml
command:
  - sh
  - -c
  - >
    bundle exec rails db:chatwoot_prepare &&
    bundle exec rails fork:super_admin:bootstrap &&
    bundle exec rails server -b 0.0.0.0 -p 3000
```

(Editing your own deploy config, not upstream Ruby — stays merge-clean.) Or run it
one-shot after a deploy: `docker compose run --rm rails bundle exec rails fork:super_admin:bootstrap`.

### 4.2 Manual (console)

Once at least one Super Admin exists, use the console's **Users → New** screen and set
the type to Super Admin. Or, out-of-band on the host (never a seeded default):

```bash
docker exec chatwoot-rails-1 bundle exec rails runner '
  sa = SuperAdmin.new(
    name: "Ops <name>",
    email: "ops-<name>@yourcompany.com",
    password: ENV.fetch("NEW_SUPER_ADMIN_PASSWORD")  # strong, unique, from your secrets manager
  )
  sa.skip_confirmation!  # nobody will click a confirmation mail for an out-of-band operator
  sa.save!
  puts "created SuperAdmin ##{sa.id} #{sa.email}"
'
```

**Rotate / revoke:**

```bash
# Reset a password:
docker exec chatwoot-rails-1 bundle exec rails runner '
  sa = SuperAdmin.find_by!(email: "ops-<name>@yourcompany.com")
  sa.password = ENV.fetch("NEW_SUPER_ADMIN_PASSWORD"); sa.save!'

# Remove access (demote or delete):
docker exec chatwoot-rails-1 bundle exec rails runner '
  SuperAdmin.find_by!(email: "ops-<name>@yourcompany.com").destroy!'
```

**Rotate the `PLATFORM_TOKEN`** (Platform App access token) from **Platform Apps** in
the console (or the Rails console) if it may be exposed — the control plane's
`CHATWOOT_PLATFORM_TOKEN` must be updated to match.

### 4.3 MFA enforcement — `SUPER_ADMIN_ENFORCE_MFA`

The `otp_*` columns on `users` exist but stock Chatwoot's Super Admin login never
checks them. The fork closes this behind a flag, in the `custom/` overlay
(upstream-merge-safe, same pattern as §4.1):

- **Enforcement (sign-in):** `custom/app/controllers/custom/super_admin/devise/sessions_controller.rb`
  (`Custom::SuperAdmin::Devise::SessionsController`), hooked onto the one upstream
  line `SuperAdmin::Devise::SessionsController.prepend_mod_with(...)`.
- **Enforcement (password-reset guard):** `devise_for :super_admins` doesn't skip
  `:recoverable`, so stock `Devise::PasswordsController` is also live at
  `/super_admin/password` — a second login-shaped path that never passes through
  the controller above. `custom/app/controllers/custom/devise_overrides/super_admin_passwords_guard.rb`
  (`Custom::DeviseOverrides::SuperAdminPasswordsGuard`) closes it: wired via
  `config/initializers/custom_prepends.rb` (Devise's stock controller ships no
  `prepend_mod_with` hook of its own, so this is the fork's documented
  mechanism for that case — see `UPSTREAM_DIFF.md` §2).
- **The flag itself:** `custom/app/services/custom/super_admin_mfa.rb`
  (`Custom::SuperAdminMfa.enforced?`) is the only reader of
  `SUPER_ADMIN_ENFORCE_MFA`. The sign-in check, the password-reset guard, and
  the sign-in form's `otp_attempt` field all call it, so they cannot drift
  apart on what "enforcement is on" means — which would leave an operator
  either typing a code nothing checks, or refused for a code the form never
  offered a box for.
- **Enrollment task (thin shim):** `lib/tasks/fork/super_admin.rake` →
  `bundle exec rails fork:super_admin:mfa_enroll`.
- **Enrollment service:** `custom/app/services/custom/super_admin_mfa_enroll.rb`
  (`Custom::SuperAdminMfaEnroll`).
- **Tests:** `spec/custom/controllers/super_admin/devise/sessions_controller_spec.rb`,
  `spec/custom/controllers/devise_overrides/super_admin_passwords_guard_spec.rb`,
  `spec/custom/services/super_admin_mfa_enroll_spec.rb`,
  `spec/custom/services/custom/super_admin_mfa_spec.rb`,
  `spec/custom/views/super_admin/devise/sessions/new_spec.rb`,
  `spec/custom/initializers/rack_attack_super_admin_password_spec.rb`,
  `spec/custom/routing/super_admin_registration_routes_spec.rb`.

**Behavior with `SUPER_ADMIN_ENFORCE_MFA` unset (default):** identical to before —
password alone signs in. Nothing here changes until you opt in.

**Behavior with `SUPER_ADMIN_ENFORCE_MFA=true`:**
- An **enrolled** operator (see enrollment below) must supply password **+** a valid
  TOTP code or a valid backup code (same `otp_attempt` field on the sign-in form —
  it accepts either) to sign in.
- An **un-enrolled** operator is **refused even with the correct password** — fail
  closed, no exceptions. The rejection names this section's enrollment task so the
  next step is obvious.
- A wrong or missing code renders the exact same generic "Invalid credentials"
  message as a bad password — the response never reveals whether an account has MFA
  enrolled. rack_attack's login throttle (§3, `config/initializers/rack_attack.rb`)
  applies unchanged, since it throttles the route, not this controller.
- **The password-reset route cannot mint a session either.** Stock Devise wires
  `/super_admin/password` (§4.0) as a second, independent login-shaped path — a
  successful reset there normally auto-signs the resource in
  (`sign_in_after_reset_password`, Devise's default), which would bypass every
  check above with zero OTP involved. With the flag on, the fork's
  `Custom::DeviseOverrides::SuperAdminPasswordsGuard` (see the Enforcement
  bullets above) suppresses that auto-sign-in for this scope: the password
  **does** get reset, but no session is minted — the operator is redirected to
  `/super_admin/sign_in` and still needs their TOTP/backup code from there if
  enrolled, or hits the un-enrolled refusal above if not. The reset routes carry
  their own rack_attack throttle (§3), so this path is no cheaper to grind on
  than the sign-in form.
- **If you enable the flag before enrolling an operator, that operator is
  locked out of `/super_admin` entirely** — the password-reset route no longer
  offers a path around that (see the bullet above). Recovery is host access.

**Enroll an operator** (must already exist — run `fork:super_admin:bootstrap`
first if not):

```bash
docker exec \
  -e SUPER_ADMIN_MFA_EMAIL='ops@yourcompany.com' \
  chatwoot-rails-1 bundle exec rails fork:super_admin:mfa_enroll
# → prints the otpauth:// provisioning URI (branded with INSTALLATION_NAME, or
#   "Chatwoot" if unset) and 10 backup codes — ONCE. Scan the URI into an
#   authenticator app and store the backup codes securely; neither is shown again.
```

Re-running against an already-enrolled operator is a **refused no-op** ("already has
MFA enrolled — unchanged") unless you explicitly add `SUPER_ADMIN_MFA_ROTATE=true`,
which issues a fresh secret + fresh backup codes (the old ones stop working) —
mirrors the `SUPER_ADMIN_ROTATE_PASSWORD` idiom in §4.1.

**Environment:**

| Var | Effect |
| --- | --- |
| `SUPER_ADMIN_ENFORCE_MFA=true` | Turns on login enforcement (§ above). Off/unset = inert. |
| `SUPER_ADMIN_MFA_EMAIL` | Operator email to enroll (required to do anything for the enrollment task). |
| `SUPER_ADMIN_MFA_ROTATE=true` | Rotate an already-enrolled operator (new secret + new backup codes). |

Only turn `SUPER_ADMIN_ENFORCE_MFA` on after every operator you rely on is enrolled —
check with `SuperAdmin.pluck(:email, :otp_required_for_login)` on the host.

## 5. Hardening checklist (production)

The app-level controls above are necessary but **not sufficient** — close these at
deploy time:

1. **Remove the default seed credential.** Never run `db/seeds.rb` (or its
   `john@acme.inc / Password1!` Super Admin) in any non-dev environment. The
   bootstrap (§4.1) removes it for you when `SUPER_ADMIN_REMOVE_DEFAULT_SEED=true`.
   Verify no Super Admin exists except the ones you created:
   `SuperAdmin.pluck(:id, :email)`.
2. **Network-restrict `/super_admin` and `/monitoring/sidekiq`.** Put them behind a
   VPN / IP allowlist / reverse-proxy auth (mTLS or SSO proxy). The operator console
   should **not** be reachable from the public internet — this is the primary
   mitigation for the public login form, and the only mitigation for any deployment
   that hasn't turned on `SUPER_ADMIN_ENFORCE_MFA` yet (item 7). Coordinate with
   `../../docs/operations/*` ingress hardening (meta-saas backlog 07).
3. **Strong, unique credentials + a secrets manager.** No shared or reused passwords;
   one Super Admin per operator so access is attributable.
4. **Keep the login and password-reset throttles on** (`rack_attack`) and alert on
   repeated `super_admin/sign_in` 401s / throttle hits — and on
   `super_admin_password/*` throttle hits, which mean someone is grinding the
   reset path (§3).
5. **HTTPS only**; `FRONTEND_URL` / `PUBLIC_API_URL` are real public HTTPS URLs.
6. **Treat installation-config and Platform-App changes as privileged.** Log and
   review them; a change to `ENABLE_SSO_ONLY_LOGIN`, `ENABLE_ACCOUNT_SIGNUP`, or a new
   Platform App is a security event.
7. **(Available — enable it) Enforce MFA for the scope.** `SUPER_ADMIN_ENFORCE_MFA`
   is built and off by default (§4.3). Enroll every operator with
   `fork:super_admin:mfa_enroll`, then set `SUPER_ADMIN_ENFORCE_MFA=true`. Until you
   do, rely on network restriction (item 2) — an un-enrolled operator is locked out
   the moment the flag goes on, so enroll first.

## 6. Relationship to the rest of the platform

- Vendors never touch this — they land in their **own** Chatwoot account as
  `administrator` via the meta-saas SSO bounce. See
  [`../../docs/operations/chatwoot-access-lockdown.md`](../../../agentic-str/docs/operations/chatwoot-access-lockdown.md)
  (SSO-only login) and `CHATWOOT_ENGINE_INTEGRATION.md` §4.5/§4.6.
- Plan limits are set by the **control plane** via the Platform API (whose token is a
  Platform App managed here), not by hand in this console. See `ENTITLEMENTS.md` /
  `PROVISIONING.md`.
- Roles overview: `ROLES_AND_CONTROL.md` (Super Admin = the platform operator).

## 7. Verification / audit commands

```bash
# Who has Super Admin? (should be only your named operators — no john@acme.inc)
docker exec chatwoot-rails-1 bundle exec rails runner 'pp SuperAdmin.pluck(:id, :email)'

# No tenant-provisioned user is a Super Admin (expect []):
docker exec chatwoot-rails-1 bundle exec rails runner \
  'pp User.where(type: "SuperAdmin").where("email LIKE ?", "%@handoff.local").pluck(:email)'

# Is the console publicly reachable? (from OUTSIDE the allowlist this must NOT return 200)
curl -s -o /dev/null -w "%{http_code}\n" https://<chatwoot-host>/super_admin/sign_in
```
