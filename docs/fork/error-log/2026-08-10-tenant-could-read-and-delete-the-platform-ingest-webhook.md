# A tenant could read the platform's webhook HMAC secret, and delete the ingest webhook permanently

- **Date**: 2026-08-10
- **Phase**: Phase 3 (control-plane integration hardening)
- **Area**: backend / webhook

## Symptom

No error output — which is why it survived. Two capabilities that should not
exist, found by a cross-repo audit run from `agentic-str` (`/gap-audit`), then
verified here against the code.

A tenant administrator — the role **every** vendor is provisioned into — could:

```text
GET /api/v1/accounts/{id}/webhooks
→ 200, and the payload includes the orchestrator-ingest webhook,
  with `"secret": "<the platform's HMAC key>"`

DELETE /api/v1/accounts/{id}/webhooks/{platform_webhook_id}
→ 200, row gone, Chatwoot silently stops delivering to the control plane
```

Reproduced as a failing spec before the fix: 4 of 7 examples fail.

## Root cause

Three upstream facts that are each individually reasonable:

1. `app/views/api/v1/accounts/webhooks/_webhook.json.jbuilder:6` renders
   `json.secret webhook.secret` — correct for a webhook the tenant created and
   owns.
2. `app/policies/webhook_policy.rb` grants `index?`/`update?`/`destroy?` on
   `@account_user.administrator?`.
3. `app/controllers/api/v1/accounts/webhooks_controller.rb` scopes both `index`
   and `fetch_webhook` to `Current.account.webhooks` — the whole account,
   including platform-managed rows.

The fork adds the fourth fact that turns them into a vulnerability: the control
plane provisions every vendor **as an account administrator**
(`agentic-str` `handoff-access.controller.ts:102` maps operator→agent, everyone
else→administrator), and it installs its own account webhook on the same
account. So "administrator" no longer means "owns everything in this account".

**Why the delete is the worse half.** The control plane's repair path is gated on
its own stored ciphertext, not on Chatwoot's state:

```ts
// agentic-str, chatwoot-provisioning.service.ts
if (account.hasWebhookSecret) return;   // hasWebhookSecret = Boolean(row.webhookSecretEnc)
```

After a tenant deletes the row, `webhookSecretEnc` is still non-null, so
`ensureWebhookSecret` returns early on every subsequent `ensureAccount` and the
webhook is **never re-created**. Chatwoot stops delivering, that tenant's AI goes
dark permanently, and nothing errors on either side.

**Why the read matters.** The secret is the HMAC key `POST /webhooks/chatwoot`
verifies with. A holder can mint valid `X-Chatwoot-Signature` headers for their
own account: inject synthetic `message_created` events to burn model tokens
against the plan cap, or spoof `conversation_status_changed → resolved` to pull a
live conversation back from the human agent mid-handoff. Scope is their own
tenant (the secret is per-account), which bounds it — it is not cross-tenant.

Same incident class as **backlog 13**, where deleting the platform-managed
service admin destroyed the account's stored API credential. That one was fixed
for `account_users`; `webhooks` received the quota exemption from that work but
never the visibility/deletion scoping.

## Fix

`custom/app/controllers/custom/api/v1/accounts/webhooks_controller.rb` — the
overlay already existed (it owns the quota exemption and the `platform_managed`
param strip); this adds two overrides to it:

```ruby
def index
  super
  @webhooks = @webhooks.where(platform_managed: false) unless platform_actor?
end

def fetch_webhook
  super
  return if platform_actor?

  raise ActiveRecord::RecordNotFound if @webhook&.platform_managed?
end
```

Four deliberate choices:

- **Scoped, not de-fielded.** `AGENTS.md` freezes existing response shapes to
  additive changes only, and a tenant's *own* webhook must keep showing its
  secret. What changes is which rows a tenant can see — the same shape
  `custom/.../agents_controller.rb:29` already applies to platform-managed
  `account_users`.
- **`super` first**, so a future upstream `index` (pagination, ordering,
  includes) is inherited rather than frozen at today's one-liner.
- **`platform_actor?` is exempt, and this is load-bearing.** The control plane
  lists webhooks to adopt its own secret (`resolveWebhookSecret`), and a
  divergence-reconcile path in `agentic-str` depends on that read. Scoping the
  platform out would have broken provisioning *and* the reconcile. The check
  keys off the persisted acting identity (`Current.account_user.platform_managed?`),
  which cannot be forged from a request.
- **404, not 403.** A tenant has no legitimate need to learn that a webhook they
  may not touch exists on their account.

No OSS file was edited; the injection point
(`Api::V1::Accounts::WebhooksController.prepend_mod_with`) already ships at the
bottom of the upstream controller. No migration — `webhooks.platform_managed`
has existed since `20260704000000` and the control plane already sets it
(`chatwoot-api.adapter.ts:390`).

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c "bundle install --quiet && bundle exec rails db:create db:schema:load && \
         bundle exec rspec spec/custom/controllers/api/v1/accounts/webhooks_controller_visibility_spec.rb"
```

→ **7 examples, 0 failures.** RuboCop clean on both files.

**Verified against a negative control, not just observed green:** with the two
overrides removed, exactly **4 of 7 fail** — the listing, the secret exposure,
the delete and the update. The other three assert *unchanged* behaviour (a tenant
still sees and can delete their own webhook; the platform actor still sees
everything) and pass either way, which is what makes the four meaningful.

Wider run: `spec/custom/controllers/api/v1/accounts/ spec/custom/services/` →
55 examples, **1 failure**, which is **pre-existing** —
`agents_controller_spec.rb:59` returns 402 on the create-guard count. Confirmed
by stashing this fix and re-running: it fails identically on the unmodified tree.

## Notes / related

- Deployment note: the migration that added `platform_managed` did **not**
  backfill. A webhook created before that column existed is `false` and would
  still be visible. New installs are unaffected — the control plane has set the
  flag on creation since `chatwoot-api.adapter.ts:390`. If an environment
  predates it, mark the row by URL before relying on this fix.
- Related: `docs/fork/adr/0002` (platform-managed resources), `adr/0005`
  (platform-actor exemption), backlog 13 (the `account_users` equivalent).
- Cross-repo: `agentic-str` `docs/troubleshooting/238` documents the third
  blocker from the same audit — a diverged webhook secret that could never heal —
  and lists these two as the mesh-crm half.
- The other lesson from that audit stands here too: this was reported by an agent
  that had fabricated an unrelated claim in the same run, so **every line above
  was re-verified against the code before anything changed**. Both
  vulnerabilities were real; a third claim in the same report (`RAILS_ENV=development`
  on a public host) was **not**, and was withdrawn — `.env` is untracked and every
  tracked deploy path sets `production`.
