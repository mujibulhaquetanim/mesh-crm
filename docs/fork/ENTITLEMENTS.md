# Entitlements & Quota Enforcement

Design goal: one source of truth (`Account#usage_limits`), one guard pattern,
one error shape — applied uniformly to every capacity-creating resource.

> **Status (2026-07-03): shipped.** All nine resources in the catalog below are
> enforced. `Custom::Account::PlanUsageAndLimits` extends `usage_limits` + the
> jsonb schema; `Custom::EntitlementService` does counting/denial logging;
> `Custom::QuotaEnforcement` renders the 402; controller guards + `QuotaGuard`
> model validations cover every create path (including channel onboarding, OAuth
> callbacks, and automation-rule clone). Boundary, bypass, and denial-shape cases
> are covered in `spec/custom` (green). The imperative phrasing below ("must",
> "the override must") documents the rules the shipped code follows.
>
> **Flow:** `create request → Pundit authorize → controller quota before_action`
> (or, for multi-path resources, `model validate on: :create`) `→
> EntitlementService#check(resource)` (count vs. `usage_limits[resource]`) `→
> allow (201) | deny → render_quota_exceeded → 402 + additive body + structured
> log`.

## Limit sources

Fork quota keys resolve in exactly two steps:

1. `accounts.limits` jsonb (per-tenant — what the SaaS control plane sets at
   purchase/upgrade via the Platform API or Super Admin),
2. `ChatwootApp.max_limit` (effectively unlimited).

Deliberately **no** `GlobalConfig` `ACCOUNT_<RESOURCE>_LIMIT` fallback for the
fork keys (unlike upstream agents/inboxes): model guards run on every record
create, and the GlobalConfig lookup costs a Redis roundtrip per save and broke
upstream specs that mock GlobalConfig strictly (see error log,
2026-07-02 GlobalConfig strict-mock entry). Upstream's own `agents`/`inboxes`
keys keep their enterprise resolution chain untouched.

## Current plan catalog — what a new / free account gets

A brand-new tenant starts on the **Trial** (free, $0) plan. The control plane
(agentic-str, renamed from meta-saas) seeds **four** plans from ONE canonical
catalog — `agentic-str/packages/contracts/src/plans.ts` (`PLAN_CATALOG`),
which both the database seed AND the public pricing page derive from, so a
price or cap change cannot move one without the other. A tenant's
`TenantEntitlement` overrides win when set.

| Cap | **Trial (free)** | Starter | Pro | Enterprise |
| --- | --- | --- | --- | --- |
| Agents | 2 | 3 | 5 | 25 |
| Teams | 2 | 4 | 7 | 25 |
| Inboxes (vendor) | 2 (+1 system → `inboxes: 3`) | 4 (→5) | 7 (→8) | 25 (→26) |
| Messages / month | 500 | 5,000 | 50,000 | 250,000 |
| LLM tokens / month | 100,000 | 2,000,000 | 20,000,000 | 100,000,000 |
| Tool calls / month | 500 | 5,000 | 50,000 | 250,000 |
| KB documents | 20 | 200 | 2,000 | 20,000 |
| MCP sources | 1 | 1 | 5 | 25 |
| Data-source connectors | 1 | 1 | 3 | 10 |
| Vendor images (live) | 50 | 250 | 1,500 | 10,000 |
| Order drafts / hour | 30 | 120 | 600 | 3,000 |
| Comment automations / month | 25 | 250 | 2,500 | 12,500 |
| Unattended replies / month | 10 | 100 | 2,500 | 12,500 |
| Allowed tools | `kb_search`, `mcp_tools`, `record_order_details` on **every** tier — see below |

**`PlanLimitsSyncService` pushes ALL THIRTEEN Chatwoot-enforced keys into
`accounts.limits` on every sync (provisioning, plan change, and the periodic
agentic-AI usage writeback)** — not just agents/teams/inboxes. The fork's
`update!(limits:)` is a wholesale REPLACE of the jsonb, not a merge, so a key
absent from the payload silently resolves to `ChatwootApp.max_limit`
(effectively unlimited) rather than "unchanged". The full key set
(`CHATWOOT_LIMIT_KEYS`, `agentic-str/apps/api/src/chatwoot/chatwoot-limits.ts`):
`agents`, `teams`, `inboxes`, `agentic_ai`, `webhooks`, `agent_bots`,
`automation_rules`, `integrations`, `labels`,
`custom_attribute_definitions`, `captain_documents`, `captain_responses`,
`emails`. Only the first three are visible in the table above because they
are the ones this document's earlier revision described; the rest are real
enforced caps with no vendor-facing tier differentiation today (same number
on every plan) except where `plan_usage_and_limits.rb`'s own resolution chain
already bounds them.

**Allowed tools does not differentiate by tier.** `crm_lookup`, `order_lookup`,
`booking` and `ticketing` were **withdrawn from sale 2026-08-03**
(`agentic-str/docs/changes/2026-08-03-pull-unbuilt-tools-from-sale.md`) — three
had no implementation anywhere (`ToolRegistry` never registered them) and the
fourth (`order_lookup`) always answered "unavailable" (`StubOrderProvider`),
so granting any of them sold nothing and burned a tenant's tool-call budget on
a dead end. They stay defined as identifiers (`WITHDRAWN_TOOLS` in
`plans.ts`) rather than deleted, because existing `Plan.allowedTools` /
`TenantEntitlementOverride.enabledCapabilities` rows already hold them and the
policy engine matches on the stored string — but no tier grants them, and the
per-tier "+ crm_lookup, order_lookup" / "+ booking, ticketing" differentiation
this table used to describe no longer exists. Every tier's real tool
differentiation today is `maxMcpSources` (1 / 1 / 5 / 25), not the tool list.

Notes:

- **The `+1` system inbox** is the platform "AI Handoff" API inbox
  (`SYSTEM_RESERVED_INBOXES`), reserved on top of the plan so a `maxInboxes: 2`
  trial still lets the vendor create **2** of their own channels (see
  `plan-limits-sync.service.ts`).
- **None of these are login / access gates.** They cap capacity and automation, not
  whether you can open or sign into an account — see the next section.

## Enforcement window: the tenant's subscription period, not a rolling 15 days

Messages/tokens/tool-calls are counted against the tenant's **own subscription
period**, not a shared clock. Exceeding one flips the tenant's `aiEnabled` to
`false` (reason `message_quota_exceeded` / `token_quota_exceeded`) →
**the AI stops auto-replying**; human replies in Chatwoot are never blocked
and no data is deleted. This is the `agentic_ai` limit surfaced here
display-only (see the last section) but enforced in NestJS.

**This replaced a rolling 15-day global window** (`QUOTA_WINDOW_DAYS`,
deleted, zero references remain) that renewed roughly twice per paid month —
so every tenant could consume about double their advertised "per month"
allowance, and the two customer-facing descriptions (marketing's "per month"
vs. the FAQ's "rolling 15-day window") openly contradicted each other. Fixed
2026-07-19
(`agentic-str/docs/changes/2026-07-19-subscription-quota-period.md`):

- The window is now `Subscription.currentPeriodStart` → the resolved period
  end, computed by the pure `resolveQuotaPeriod(subscription, now, graceDays)`.
- **A successful payment is what advances the period — nothing else does.**
  There is still no scheduled reset job.
- **The lapse is deliberately NOT self-lifting.** A missed payment does
  **not** start a fresh window; usage keeps accruing against the same one.
  Letting a payment slip must never be cheaper than paying — the previous
  15-day window rolled on its own schedule regardless of payment, which was
  effectively a free quota refill for a non-paying tenant. Automation is cut
  separately once the paid period passes its grace window
  (`isPaidPeriodExpired` → `subscription_expired`); nothing about the quota
  window itself grants a reprieve.
- A trial gets one allowance for its whole 14 days, anchored at signup — not
  renewed mid-trial the way the old window did.

## Not a limit: why a day-old account seems "inaccessible"

A common confusion: *"I registered an account yesterday and can't get into it today,
but creating a new one drops me straight into Chatwoot — is the free plan limiting
me?"* **No.** The account still exists with its normal caps; this is the **SSO-only
lockdown**, not a quota:

- `ENABLE_SSO_ONLY_LOGIN=true` → **native Chatwoot login is refused**. A tenant reaches
  Chatwoot **only** by bouncing through the meta-saas login, which mints a fresh
  Chatwoot session.
- That session **expires** (it's not a permanent login). A day later, navigating to
  Chatwoot directly can't sign you in, because native login is off.
- **Re-enter through the meta-saas dashboard** (`EXTERNAL_LOGIN_URL`, e.g.
  `http://localhost:3002/login`) with your vendor credentials — it re-bounces you into
  your **existing** account. "Opening a new account" simply runs that same fresh SSO
  bounce, which is why *that* lands you in Chatwoot.

See [`chatwoot-access-lockdown.md`](../../../agentic-str/docs/operations/chatwoot-access-lockdown.md)
for the lockdown mechanism and [`SUPER_ADMIN.md`](./SUPER_ADMIN.md) for operator access.

## Fork extension: `Custom::Account::PlanUsageAndLimits`

`custom/app/models/custom/account/plan_usage_and_limits.rb`, prepended onto
`Account` after the enterprise module:

- `usage_limits` → `super.merge(teams:, webhooks:, agent_bots:, labels:, custom_attribute_definitions:, automation_rules:, integrations:)`,
  each resolved with the same `get_limits(...)`-style chain.
- Override `validate_limit_keys` to extend the JSON schema: the enterprise
  schema uses `additionalProperties: false` with a fixed key list
  (`plan_usage_and_limits.rb:162-180`), so writing `{"teams": 5}` into
  `accounts.limits` **fails validation today**. The custom override must allow
  the new keys (call pattern: replicate the schema with the extended property
  list; do not loosen `additionalProperties`).

## Policy façade: `Custom::EntitlementService`

A thin, UI-independent, easily-mockable service so guards and jobs don't
re-implement counting:

```ruby
Custom::EntitlementService.new(account).check(:teams)
# => #<Result allowed: false, resource: :teams, current: 5, limit: 5>
```

Responsibilities: current count (per the catalog below), limit lookup via
`account.usage_limits`, allow/deny, and structured denial logging
(`Rails.logger.warn` with account_id/resource/current/limit). No HTTP, no UI.

## Resource catalog

"Guard layer" = where denial must be enforced so **no** path bypasses it.
Model-layer guards (a `validate ... on: :create` added via `Custom::<Model>`
concern) are used whenever more than one code path creates the row.

| Resource | Count query | Create paths | Guard layer |
| --- | --- | --- | --- |
| Agents | confirmed, non-blocked agent `account_users` (match existing `can_add_agent?` logic in `agents_controller.rb:96-101`) | `AgentsController#create/#bulk_create` (already guarded), invitation/`AgentBuilder` flows | Keep controller guard; add guard inside `AgentBuilder` so non-controller callers are covered |
| Teams | `account.teams.count` | `TeamsController#create` | Controller + model |
| Inboxes | `account.inboxes.count` (existing guard: `inboxes_helper.rb:118`) | `InboxesController#create` **and every channel controller** (`channels/`, `callbacks_controller`, instagram/tiktok/twitter onboarding) that builds an inbox | **Model-level on `Inbox`** (many paths); keep helper guard for the clean API error |
| Agent bots | `account.agent_bots.count` | `AgentBotsController#create`, platform API agent-bot create | Model-level on `AgentBot` |
| Webhooks | `account.webhooks.count` | `WebhooksController#create` | Controller + model |
| Labels | `account.labels.count` | `LabelsController#create`, inline label creation from conversation UI | Model-level on `Label` |
| Custom attribute definitions | `account.custom_attribute_definitions.count` | `CustomAttributeDefinitionsController#create` | Controller + model |
| Automation rules | `account.automation_rules.count` | `AutomationRulesController#create` (+ clone/copy action if present) | Controller + model |
| Integrations | `account.hooks.count` (`Integrations::Hook`) | `Integrations::HooksController#create`, OAuth callback flows that create hooks | Model-level on `Integrations::Hook` |

Notes:

- Edits and deletes stay unrestricted (capacity can always be reclaimed).
- Model-level guard raises/records a validation error; controllers translate
  it (or their own before_action) into the shared 402 response.
- Guards are check-then-create (no DB-level constraint), so two concurrent
  creates can land 1–2 records past a cap. Accepted: caps are billing
  boundaries, not hard invariants, and this matches upstream's own agent/inbox
  limit checks.
- Verify each "create paths" cell with
  `rg -n "<Model>.create|<model>s.build|<Model>Builder" app enterprise custom`
  during Phase 1 (inventory) — the table is the starting map, not gospel.
- **Platform-managed exclusion (see below):** the `agents`, `agent_bots`, and
  `webhooks` counters are scoped to `where(platform_managed: false)`, so platform
  infrastructure never consumes a tenant slot.

## Platform-managed resources (infrastructure exclusion)

Some resources provisioned inside a tenant account are **platform
infrastructure**, not tenant-billable seats: the **AI reply user** (a
`role: agent` `account_user`, ADR-0006), its **account webhook** (orchestrator
ingest), and the platform's **automation service admin `account_user`** (behind
`USER_TOKEN`). Charging a plan slot for the platform's own automation is wrong — a
"3 agents / 2 webhooks" plan must give the tenant all of those, not fewer.

These carry `platform_managed: true` (column on `agent_bots`, `webhooks`,
`account_users`; default `false`) and are **excluded from entitlements entirely**:

- **Counted out** — `RESOURCE_COUNTERS` for `agents`/`agent_bots`/`webhooks` filter
  `where(platform_managed: false)`. For `agents` this is enforced end-to-end:
  `Custom::Api::V1::Accounts::AgentsController#agents` scopes the tenant-facing
  finder to `platform_managed: false`, so infra is excluded from the **agents list**
  (`index`), the **create-guard count** (`can_add_agent?` builds on the same
  finder), **edit/destroy lookup** (`fetch_agent` → 404 on an infra id, protecting
  the service admin whose token is the account credential), and the limits
  endpoint's `agents.consumed` (re-derived via `Custom::EntitlementService`).
- **Never blocked** — both guard layers short-circuit for a platform-managed
  create: the model guard (`QuotaGuard#ensure_quota_capacity`) and the controller
  guards (`check_webhooks_quota` / `check_agent_bots_quota`). So infrastructure
  provisions even when the tenant is at their cap.

On the Application API (`webhooks`/`agent_bots`), the flag is honored **only when
the acting identity is itself platform-managed** — `Current.account_user.platform_managed?`
(`Custom::Concerns::PlatformActor`). Any other caller, including a tenant
`administrator`, has the `platform_managed` key stripped from permitted params, so
they cannot self-exempt and the resource still counts against the plan. The
Platform-API `account_users` create sets the flag directly and is safe by
construction (super-admin platform token only). Tenant-created resources omit the
flag and count normally — the change is fully backward compatible.
See [ADR-0005](./adr/0005-platform-managed-resources.md).

## Error contract

Additive extension of the existing `render_payment_required` behavior — same
status (402), same `error` key, new machine-readable fields:

```json
{
  "error": "Your plan allows 3 agents.",
  "error_code": "quota_exceeded",
  "resource": "agents",
  "current": 3,
  "limit": 3
}
```

Implemented once as `check_quota(resource)` in the
`Custom::Concerns::QuotaEnforcement` controller concern (checks the
entitlement and renders the 402 on denial); never inline the JSON.
The two pre-existing guards (agents, inboxes) may be migrated to the new
renderer **only** because the change is additive (same status, `error` key
preserved).

The message string goes through i18n (`en.yml`), e.g.
`quota.exceeded: "Your plan allows %{limit} %{resource}."`.

## UI rules

- Read usage from the backend (`usage_limits` is already serialized on the
  account payload for agents/inboxes — extend the same serializer path for
  the new keys; verify in `app/views/api/v1/accounts/` / account store module).
- At cap: **disable** create buttons with a tooltip showing `current/limit`
  and upgrade copy (i18n via `en.json`, brand-safe via `useBranding`).
- Always render the backend `error` message on 402 — UI state can be stale.
- One shared composable (e.g. `useQuota(resource)`) instead of per-component
  logic.

## Permissions interplay

Quota checks run **in addition to** Pundit policies, never instead of them.
Order in controllers: authenticate → authorize (policy) → quota → act.
Super-admin/platform paths (e.g. Platform API account creation) are
installation-level and not quota-guarded, but platform-created *tenant
resources* (agent bots) still hit model-level guards.

## Testing (see IMPLEMENTATION_PLAN.md for the full matrix)

- Service specs: boundary at `limit - 1`, `limit`, unlimited default, per-key
  override in `accounts.limits`.
- Request specs per resource: create under cap (201), at cap (402 with full
  error shape), edit at cap (200), delete frees capacity (next create 201).
- Bypass-path specs: channel-created inbox at cap fails; `AgentBuilder` at cap
  fails; OAuth-created hook at cap fails.

## Reply authority: nothing but the agent may message a customer

The control plane's agent is the only reply authority on a platform-run account
(agentic-str ADR-0006). That is why plan sync force-disables Chatwoot Captain
(`captain_integration`, `captain_integration_v2`, `captain_v1_action_classifier`
— all pushed as explicit `false`) and caps `agent_bots` at 0.

`automation_rules` is deliberately **not** capped at 0: the useful half of
automations is routing (`assign_agent`, `assign_team`, `add_label`,
`remove_label`, `snooze_conversation`, `resolve_conversation`) and none of it
competes with the agent. Two actions do — `send_message` and `send_attachment`,
both of which build an outgoing, non-private message via
`Messages::MessageBuilder` on the same `message_created` event the agent is
answering. Without a guard a vendor could hand-build exactly the second reply
path the Captain flags exist to prevent.

- **Where:** `custom/app/models/custom/automation_rule.rb`
  (`Custom::AutomationRule::CUSTOMER_FACING_ACTIONS`), resolved through the
  upstream `AutomationRule.prepend_mod_with` hook.
- **How:** a validation, refused at save with
  `errors.automation_rule.customer_facing_action` — not a silent drop at
  execution time. A rule that saves and then never fires is worse than one that
  refuses to save.
- **Scope:** only accounts where the platform has capped `agent_bots` at 0 in
  `accounts.limits` — the control plane's own machine-readable statement that
  nothing but its agent replies here. Stock Chatwoot accounts (no projected
  limits) are untouched; that is also what keeps the upstream automation suite
  green (unconditional, the validation reds 65 of its 116 examples).
- **Only when `actions` is being written:** a rule created before this guard
  existed stays renameable, deactivatable, and deletable — editing its actions is
  what forces the fix. Consequence, accepted deliberately: such a rule keeps
  firing until someone edits or deletes it. Sweeping them is an ops task (audit
  `AutomationRule` rows for these two action names), not something to bury in a
  validation.
- **Still allowed:** `add_private_note` (internal only) and `send_email_to_team`
  (internal recipients).
- **Tests:** `spec/custom/models/custom/automation_rule_spec.rb`.
- **Not covered:** the dashboard still *offers* "Send a message" in the
  automation builder; the vendor gets the error on save rather than a hidden
  option. Hiding it is a frontend change, deliberately not bundled here.

### The second path: campaigns

Blocking `send_message` on automations while leaving campaigns open would close
the door and leave the window — a vendor wanting a second outbound path would
simply build it here instead.

A campaign is an automated customer-facing send that Chatwoot delivers on its
own: `one_off` on a WhatsApp/SMS inbox is a scheduled bulk send to an audience,
`ongoing` on a Website inbox fires at visitors matching `trigger_rules`. Neither
passes through the platform agent.

There is a second, independent reason to refuse them, and it is the one that
bites in production: campaigns deliver through Chatwoot directly, so their
messages never reach the platform's usage metering or audit trail (agentic-str
CLAUDE.md §11, §12). That is untracked spend on a channel the tenant is billed
for, and a customer-visible action with no audit row.

- **Where:** `custom/app/models/custom/campaign.rb`. No upstream edit was
  needed — `app/models/campaign.rb` already ends with
  `Campaign.include_mod_with('Campaign')`, and `ChatwootApp.extensions` includes
  `custom`.
- **Scope:** identical to the automation guard, and *shared with it* —
  `Custom::Concerns::PlatformReplyAuthority#platform_reserves_replies?`. The two
  guards must agree: an account where automations may not reply but campaigns
  may is not a policy, it is a bug, and two copies of the predicate are how that
  happens. Upstream campaign suite stays green (79 examples).
- **Only when the campaign is being ARMED**, which is broader than the
  automation guard can be, because a campaign has an `enabled` flag:

  | Refused | Allowed |
  | --- | --- |
  | creating one | disabling one |
  | re-enabling a disabled one | renaming / editing its description |
  | editing message, inbox, audience, trigger rules or schedule **while enabled** | editing those same fields once it is disabled |
  | | deleting one |

  Same accepted consequence as automations: a pre-existing *enabled* campaign
  keeps running until someone disables or deletes it. Sweeping those is an ops
  task — audit `Campaign.where(enabled: true)` on platform accounts.
- **Tests:** `spec/custom/models/custom/campaign_spec.rb` (4 of its 9 examples
  fail without the validation; the other 5 assert what stays permitted).
- **Not covered:** as with automations, the dashboard still offers the Campaigns
  UI; the vendor gets the error on save rather than a hidden nav item. Hiding it
  is a frontend change, deliberately not bundled here.

## Agentic-AI limit (externally enforced, display-only)

The agentic-AI (automated workflow) quota is **enforced by the external NestJS
backend**, not Chatwoot. Chatwoot only surfaces it so the dashboard can warn the
tenant. It rides the existing limits pipeline rather than a parallel store:

- Contract (control plane / NestJS writes via the Platform API, additively):
  - cap → `accounts.limits['agentic_ai']` (same jsonb as every other limit).
  - running usage → `accounts.custom_attributes['agentic_ai_usage']`, written as
    a **sparse patch**: the fork gives `custom_attributes` on
    `PATCH /platform/api/v1/accounts/:id` merge-patch semantics
    (`Custom::Platform::Api::V1::AccountsController`) so the periodic usage
    writeback can never wipe Chatwoot-owned attributes (`marked_for_deletion_at`,
    billing/plan keys). `limits` keeps upstream replace semantics — resend the
    complete cap set.
- Because `validate_limit_keys` uses `additionalProperties: false`, `agentic_ai`
  must be whitelisted in the schema or the Platform API write is rejected (422).
  It lives in `Custom::Account::PlanUsageAndLimits::EXTERNAL_LIMIT_KEYS`, kept
  **separate from `QUOTA_RESOURCES`** on purpose: `EXTERNAL_LIMIT_KEYS` are
  schema-valid but get no counter, no `usage_limits` merge, and no create-guard —
  Chatwoot stores and displays them but never enforces them.
- `GET /enterprise/api/v1/accounts/:id/limits` (`Custom::Enterprise::Api::V1::AccountsController`)
  emits `agentic_ai: { allowed, consumed }` in the standard shape, but **only
  when a cap is set** — accounts without agentic AI get an unchanged response.
- UI: `dashboard/fork/AgenticAiLimitBanner.vue` reuses `useQuota('agentic_ai')`
  and renders a global warning banner (admins only) when `consumed >= allowed`.
  It is display-only — there is no Chatwoot-side create path or 402 for this
  resource (NestJS owns enforcement), so it has no `EntitlementService`
  counter/guard.
