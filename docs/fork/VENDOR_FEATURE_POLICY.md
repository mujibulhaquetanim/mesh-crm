# Vendor feature policy and brand check

**The rule:** a vendor sees the inbox as **Zasmate**, and cannot see or use a
Chatwoot feature that duplicates something the platform owns. The check in
`scripts/fork-policy/check.py` enforces both, before every push and every
rebuild, and against the running inbox after every release.

## Who is who

| Identity | Chatwoot role | `platform_managed` | What this policy lets it do |
| --- | --- | --- | --- |
| Vendor (the business's people) | `administrator` | `false` | everything **except** the features below |
| Platform service user (provisioning) | `administrator` | `true` | everything, including the features below |
| AI reply user (posts the AI's replies) | `agent` | `true` | what an agent can do |

Vendors are administrators on purpose: the inbox is their full workspace
(agentic-str `createAccountAgent`). So upstream's policies alone let a vendor
do everything an administrator can. The fork narrows that for the features
listed here, and keys the exception off the persisted `platform_managed` flag
(`Custom::Concerns::PlatformActor`), never a request parameter.

## What is hidden and refused

| Feature | Why it conflicts | Hidden by | Refused by |
| --- | --- | --- | --- |
| **Agent bots**: Settings → Bots, and the inbox "Bot configuration" tab | A bot on an inbox parks every new conversation as `pending` for that bot: a second reply path beside our AI, which also hides conversations from the vendor's agents. The platform does not use agent bots. | account flag `agent_bots: false`, sent by the platform on every plan sync (agentic-str `chatwoot-features.ts`) | `Custom::Api::V1::Accounts::AgentBotsController` (every action) and `Custom::Api::V1::Accounts::InboxesController` (`agent_bot`, `set_agent_bot`): 403 |
| **OpenAI integration** (reply suggestions, rewrite, summaries) | A second AI writing customer replies, with a key and model the vendor supplies | `Custom::Integrations::App#active?` drops it from Settings → Integrations | `Custom::Api::V1::Accounts::Integrations::HooksController` (`create`, `update`, `process_event`): 403 |
| **Dialogflow integration** | A second bot answering customers by itself | same as above | same as above, and `Custom::Integrations::Hook#disabled?` stops hooks created before the policy from firing |
| **Captain** (Chatwoot's own AI) | same reason | the platform forces every `captain_*` account flag false | not reachable without the flag. Captain is enterprise, and paid features stay hidden (UPSTREAM_SYNC.md §5b) |
| **Paid-only surfaces** (Calls, Security/SAML, SLA, Audit logs, Custom roles) | no licence | `IS_ENTERPRISE=false` to the frontend (`Custom::DashboardController`) | upstream's own licence checks |

The one list both layers read is `Custom::VendorFeaturePolicy`
(`custom/app/services/custom/vendor_feature_policy.rb`). A refusal answers:

```json
{ "error": "This feature is managed by the platform for your account: …",
  "error_code": "feature_managed_by_platform" }
```

A vendor can still **delete** an OpenAI or Dialogflow hook that existed before
the policy. That's the only action left open, so the vendor can clean it up.

## The brand

Every vendor-visible surface says **Zasmate**. The surfaces live in two
different places, which is why the check has two modes:

| Surface | Lives in | Checked by |
| --- | --- | --- |
| English UI strings (dashboard, widget, survey) | `app/javascript/**/i18n/locale/en*.json` | `--tree` |
| Backend English strings | `config/locales/en.yml` | `--tree` |
| Installed-app window name | `public/manifest.json` | `--tree` and `--live` |
| Logos | `public/brand-assets/*.svg` | `--tree` and `--live` |
| Browser tab title template | `app/views/layouts/vueapp.html.erb` (must read `INSTALLATION_NAME`) | `--tree` |
| Tab title, product name, brand/legal links | **database rows** (`InstallationConfig`) | `--live` only |

⚠ The database rows are the ones that have gone wrong most often: the title
said "Chatwoot" on production after the rebrand was merged (2026-09-14),
after a run against the wrong database (2026-09-24), and again on 2026-09-27
after a correct run on 2026-09-25. A rebuild never changes them. Fix them with
`REBRAND_PRODUCTION.md`, then run `--live`.

Only `en` files are checked: other locales come from Crowdin (root CLAUDE.md).
Identifiers are not copy. Keys such as `UPDATE_CHATWOOT`, variables such as
`{latestChatwootVersion}`, `X-Chatwoot-*` headers and `window.chatwootSettings`
stay as they are (WHITE_LABEL.md, Cautions).

## When the check runs

| When | Command | Blocks |
| --- | --- | --- |
| every `git push` (once per clone: `scripts/fork-policy/install-pre-push-hook.sh`) | `check.py` | the push |
| after an upstream sync merge, before the PR | `check.py` | the PR (UPSTREAM_SYNC.md §6) |
| before building an image, on the fresh build clone | `check.py --tree /tmp/mesh-crm-build` | the build (agentic-str `docs/guide/06`) |
| after the box runs the new image, and after any branding row change | `check.py --live https://inbox.zasmate.com` | calling the release done |
| after changing the checker | `scripts/fork-policy/check.test.sh` | merging the change |

Read the `RESULT:` line. `NOT SAFE TO SHIP` means stop.

## Upstream specs this policy fails on purpose

Upstream's own specs expect an administrator to manage agent bots and AI
integrations. With this policy they get a 403 instead. **Do not edit those
upstream specs** (every sync would conflict on them). The expected failures
are listed here so a sync baseline can tell them apart from real regressions:

<!-- EXPECTED-UPSTREAM-FAILURES:START -->
Measured 2026-09-27 over the 8 upstream spec files for the overlaid surfaces
(agent bots, inboxes, integration hooks and apps, `Integrations::Hook` / `App`,
`HookJob`, `HookListener`): **265 examples, 0 failures on `develop` before the
policy, 25 failures after**. Each one is below. Any failure NOT on this list is
a real regression.

```text
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:19 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots when it is an authenticated agent returns all the agent_bots in account along with global agent bots
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:32 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots when it is an authenticated agent properly differentiates between system bots and account bots
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:59 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots when it is an authenticated administrator returns the account bot access token
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:68 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots when it is an authenticated administrator supports API token authentication
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:88 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated agent shows the agent bot
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:98 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated agent will show a global agent bot
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:115 # Agent Bot API GET /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated administrator returns the account bot access token
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:138 # Agent Bot API POST /api/v1/accounts/{account.id}/agent_bots when it is an authenticated user creates the agent bot when administrator
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:171 # Agent Bot API PATCH /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated user updates the agent bot
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:204 # Agent Bot API PATCH /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated user updates avatar and includes thumbnail in response
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:220 # Agent Bot API PATCH /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated user updated avatar with avatar_url
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:241 # Agent Bot API DELETE /api/v1/accounts/{account.id}/agent_bots/:id when it is an authenticated user deletes an agent bot when administrator
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:285 # Agent Bot API DELETE /api/v1/accounts/{account.id}/agent_bots/:id/avatar when it is an authenticated user delete agent_bot avatar
spec/controllers/api/v1/accounts/agent_bots_controller_spec.rb:306 # Agent Bot API POST /api/v1/accounts/{account.id}/agent_bots/:id/reset_access_token when it is an authenticated user regenerates the access token when administrator
spec/controllers/api/v1/accounts/inboxes_controller_spec.rb:1275 # Inboxes API GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/agent_bot when it is an authenticated user returns empty when no agent bot is present
spec/controllers/api/v1/accounts/inboxes_controller_spec.rb:1285 # Inboxes API GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}/agent_bot when it is an authenticated user returns the agent bot attached to the inbox
spec/controllers/api/v1/accounts/inboxes_controller_spec.rb:1315 # Inboxes API POST /api/v1/accounts/{account.id}/inboxes/:id/set_agent_bot when it is an authenticated user sets the agent bot
spec/controllers/api/v1/accounts/inboxes_controller_spec.rb:1334 # Inboxes API POST /api/v1/accounts/{account.id}/inboxes/:id/set_agent_bot when it is an authenticated user disconnects the agent bot
spec/controllers/api/v1/accounts/integrations/hooks_controller_spec.rb:31 # Integration Hooks API POST /api/v1/accounts/{account.id}/integrations/hooks when it is an authenticated user creates hooks if admin
spec/controllers/api/v1/accounts/integrations/apps_controller_spec.rb:36 # Integration Apps API GET /api/v1/integrations/apps when it is an authenticated user will not return sensitive information for openai app for agents
spec/controllers/api/v1/accounts/integrations/apps_controller_spec.rb:90 # Integration Apps API GET /api/v1/integrations/apps when it is an authenticated user returns visible hook settings for openai app for admins
spec/controllers/api/v1/accounts/integrations/apps_controller_spec.rb:102 # Integration Apps API GET /api/v1/integrations/apps when it is an authenticated user redacts secrets and only returns visible settings for openai hooks
spec/jobs/hook_job_spec.rb:55 # HookJob when handleable events like message.created calls Integrations::Dialogflow::ProcessorService when its a dialogflow intergation
spec/listeners/hook_listener_spec.rb:46 # HookListener#message_updated when hook is configured triggers hook job
spec/listeners/hook_listener_spec.rb:74 # HookListener hook job enqueuing behavior when hook is enabled and app_id is supported enqueues the job for dialogflow
```
<!-- EXPECTED-UPSTREAM-FAILURES:END -->

## Adding a feature to the policy

1. Decide it with the owner: does it duplicate something the platform owns
   (replies, AI, knowledge base, billing), or give the vendor control the
   platform needs to keep?
2. Hide it: an account feature flag sent as `false` by the platform
   (agentic-str `chatwoot-features.ts` + its spec), or a `custom/` overlay if
   no flag gates it.
3. Refuse it: a `before_action` in the controller's `custom/` overlay, using
   `refuse_platform_managed_feature` and `platform_actor?`.
4. Add it to `Custom::VendorFeaturePolicy`, a `POLICY_REQUIREMENTS` line in
   `check.py`, a case in `check.test.sh`, and examples in
   `spec/custom/controllers/api/v1/accounts/vendor_feature_policy_spec.rb`.
5. Add a row to the table at the top of this file.

A new integration app from upstream makes `check.py` print
`warn policy.new_integration`. Classify it: add it to `BLOCKED_APPS` in
`check.py` and to `BLOCKED_INTEGRATION_APPS` in the policy module (the check
fails if the two lists differ), or to `ALLOWED_APPS` in `check.py`.
