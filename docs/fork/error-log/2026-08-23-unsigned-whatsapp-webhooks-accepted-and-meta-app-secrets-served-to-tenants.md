# Unsigned WhatsApp webhooks were accepted, and Meta app secrets were served to every tenant admin

- **Date**: 2026-08-23
- **Phase**: Phase 3 (Meta channel integration hardening)
- **Area**: backend / webhook

## Symptom

No error output — the same reason as the 2026-08-10 entry: both are
*capabilities that should not exist*, not failures. Found by a review of the
platform's WhatsApp integration and then verified here against the code.

```text
POST /webhooks/whatsapp/<tenant_phone_number>
     Content-Type: application/json
     (no X-Hub-Signature-256 header at all)
     {"object":"whatsapp_business_account","entry":[...]}
→ 200 OK, and Webhooks::WhatsappEventsJob is queued with the payload
```

…on any **manual-source `whatsapp_cloud`** inbox — which is every WhatsApp
inbox this platform provisions. The forged payload becomes a real inbound
customer message, and the AI agent answers it.

And, on the same channel:

```text
GET /api/v1/accounts/{id}/inboxes            (as an account ADMINISTRATOR)
→ 200, each WhatsApp inbox carries the whole provider_config jsonb —
  including "app_secret" / "app_secret_key" / "client_secret" / "api_secret"
  if the operator ever put one there
```

## Root cause

Four facts, each individually reasonable:

1. Upstream (#14280) verifies `X-Hub-Signature-256` but only **requires** it
   when the channel can prove a secret —
   `app/controllers/webhooks/whatsapp_controller.rb:36-42`:
   blank channel → required; `provider != 'whatsapp_cloud'` → not required;
   an app secret in `provider_config` → required;
   `provider_config['source'] == 'embedded_signup'` → required;
   **otherwise → not required.**
2. `#meta_app_secrets` (`:25-30`) already offers the installation-wide
   `WHATSAPP_APP_SECRET` as a verification *candidate*. It just never made
   verification mandatory.
3. `app/views/api/v1/models/_inbox.json.jbuilder:137` serializes the entire
   `provider_config` to any account **administrator**, on index and show, with
   no redaction.
4. The fork adds the fact that turns these into a vulnerability: the control
   plane provisions vendors as account **administrators** and creates
   **manual-source** `whatsapp_cloud` inboxes — deliberately writing no app
   secret into `provider_config`, precisely because fact 3 would publish it.

So the endpoint landed in the worst available state: the installation *has* a
secret (`WHATSAPP_APP_SECRET`, used by `Whatsapp::FacebookApiClient`), the
endpoint is willing to check it, and it accepted unsigned POSTs anyway. And the
only "supported" way to make upstream require a signature — putting the secret
in `provider_config` — would have handed a **Meta-app-wide** credential to every
tenant admin. An app secret is not per-inbox: holding it forges
`X-Hub-Signature-256` for every inbox on the same Meta app (other tenants
included) and mints `appsecret_proof` for Graph calls.

The two halves are one finding: the disclosure is *why* the secret is not in
`provider_config`, and the secret's absence is *why* nothing was required.

## Fix

Two overlays plus one call site. No upstream controller or model was edited.

1. **`custom/app/controllers/custom/webhooks/whatsapp_controller.rb`** (new,
   prepended from `config/initializers/custom_prepends.rb` — the controller
   ships no `prepend_mod_with` hook):

   ```ruby
   def meta_signature_verification_required?
     return true if super
     return true if whatsapp_channel.blank?
     return false unless whatsapp_channel.provider == 'whatsapp_cloud'

     meta_app_secrets.any?(&:present?)
   end
   ```

   Phrased as *"if we can verify, we must"* rather than as another list of
   conditions, so a future upstream that teaches `#meta_app_secrets` a new
   secret source is covered instead of silently reopening this. Two things are
   deliberately untouched: the `GET` verify handshake (Meta signs deliveries,
   not subscriptions — requiring one there makes an inbox unregisterable) and
   360dialog inboxes (`provider == 'default'`), which carry no signature at all.

2. **`custom/app/models/custom/channel/whatsapp.rb`** (new, on the
   `Channel::Whatsapp.prepend_mod_with` line upstream already ships) —
   `#provider_config_without_app_secrets` drops exactly
   `MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS`, reusing the concern's own
   list so the two can never disagree about what a secret is. `api_key` is
   **not** redacted: it is the channel's own WABA-scoped send token and the
   dashboard reads it back.

   The same file carries a `before_save` that **retains** a stored app secret
   across a write that omits it. That is load-bearing, not defensive:
   `provider_config` is a jsonb column the inbox controller replaces wholesale,
   and the dashboard edits it read-modify-write
   (`ConfigurationPage.vue:176` posts `{ ...inbox.provider_config, api_key }`),
   so redaction alone would make "rotate the API key" silently erase the app
   secret and switch verification off. Sending the key blank still clears it.

3. **`app/views/api/v1/models/_inbox.json.jbuilder`** (`:137` before, `:141`
   after the comment block) — one line, swapping
   `try(:provider_config)` for `try(:provider_config_without_app_secrets)`.
   Jbuilder templates cannot be prepended and shadowing this high-churn file
   under `custom/app/views` would freeze it silently, so this is the fork's
   **only** `app/views` edit and its only non-additive response change. Both are
   catalogued in `UPSTREAM_DIFF.md` §4.2.

One upstream spec was narrowed:
`spec/controllers/webhooks/whatsapp_controller_spec.rb`'s "skips signature
validation for manual whatsapp cloud channels…" ran with `WHATSAPP_APP_SECRET`
**set** (harmless upstream, since that path skipped verification either way). It
now unsets it, so it still pins upstream's behaviour for an installation that
configured no secret.

## Verification

⚠️ **The specs below were written but NOT executed** — they are unrun as of this
entry. There is no local Ruby (by design, `DEV_SETUP.md` §0), and the rspec
stack's `test` service is pinned to the image `mesh-crm-rails:development`,
which does not exist on this machine; building it was out of scope for this
change (the prod-local stack was up and had to stay untouched). Run them before
trusting the fix:

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml \
  run --rm test bundle exec rails db:create db:schema:load

docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  bundle exec rspec \
    spec/custom/controllers/webhooks/whatsapp_controller_spec.rb \
    spec/custom/models/custom/channel/whatsapp_spec.rb \
    spec/custom/controllers/api/v1/accounts/inbox_provider_config_redaction_spec.rb \
    spec/controllers/webhooks/whatsapp_controller_spec.rb \
    spec/controllers/api/v1/accounts/inboxes_controller_spec.rb
```

Expected: **21** fork examples green (7 + 9 + 5), and the two upstream files
green (the second is the regression surface for the redaction — it asserts
`provider_config` is present for an admin, absent for an agent, and that a
`provider_config` PATCH round-trips).

**Negative control to run at the same time** (the 2026-08-10 lesson: a guard
that has never failed may be guarding nothing) — comment out the
`Custom::PrependOnce.call(Webhooks::WhatsappController, …)` entry and re-run:
exactly **2** examples must fail, both in the "when the installation has a
global WhatsApp app secret" context ("rejects an unsigned POST…", "rejects a
POST signed with the wrong secret"). The other 5 in that file assert *unchanged*
behaviour — a signed POST is accepted, 360dialog stays unsigned, the handshake
stays open, the legacy no-secret installation is untouched — and pass either
way, which is what makes the 2 meaningful. Then restore it and revert the
jbuilder line to `try(:provider_config)`: **3** of the 5 redaction examples must
fail (the two that assert *unchanged* behaviour — non-secret keys still render,
an agent still gets none — pass either way).

What *was* executed, in a throwaway container off the existing
`mesh-crm:development` image (`--network none`, repo mounted read-only, no
compose project, nothing running touched):

```sh
docker run --rm --network none --entrypoint ruby \
  -v "$PWD":/app:ro -w /app mesh-crm:development -c <each changed .rb>
# → Syntax OK (7/7)

docker run --rm --network none --entrypoint bundle \
  -v "$PWD":/app:ro -w /app -e HOME=/tmp mesh-crm:development \
  exec rubocop --force-exclusion <the 7 changed .rb files>
# → 7 files inspected, no offenses detected
```

## Notes / related

- Same incident class as
  [2026-08-10](./2026-08-10-tenant-could-read-and-delete-the-platform-ingest-webhook.md):
  a secret rendered by a jbuilder partial to a role that upstream reasonably
  treats as the account owner, but which this fork hands to every vendor. That
  one was fixed by scoping which ROWS a tenant sees; this one could not be —
  the row is the tenant's own inbox — so it is the first fork change to remove
  FIELDS from a response.
- `Channel::Sms` (Bandwidth) also stores an `api_secret` in `provider_config`
  and authenticates outbound sends with it (`app/models/channel/sms.rb:86`).
  It is untouched: the overlay is on `Channel::Whatsapp`, and the jbuilder only
  serializes `provider_config` inside `if resource.whatsapp?`. Pinned by a spec
  so a future widening has to be deliberate.
- Nothing in Chatwoot *writes* the four redacted keys on a WhatsApp channel —
  no service, job, or frontend path — so they are operator-placed values only.
  That is what makes both the redaction and the retention safe.
- `UPSTREAM_DIFF.md` §2 (the two overlays), §4.2 (the view edit and its
  silent-revert risk on an upstream pull), §6 (the narrowed upstream spec).
