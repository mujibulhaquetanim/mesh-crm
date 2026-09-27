# Production runs the MIT core only (community edition)

**Decided 2026-09-27 by the owner.** The production inbox image contains the
MIT-licensed Chatwoot core plus this fork's `custom/` layer, and **no
`enterprise/` code**. The repository still carries `enterprise/` exactly as
upstream ships it, so upstream syncs stay conflict-free. It's removed only in
the build clone, the same step upstream uses for its own community image
(`.github/workflows/publish_foss_docker.yml`).

## Why

1. **Licence.** `enterprise/LICENSE` allows production use (including modified
   copies) only with a paid Chatwoot Enterprise subscription. This installation
   has none. The MIT core carries no such condition: it can be renamed and
   rebranded freely.
2. **Branding.** While `enterprise/` is loaded, `Enterprise::Internal::CheckNewVersionsJob`
   runs `Internal::ReconcilePlanConfigService` every night at 00:00 UTC. On the
   `community` plan that service rewrites `INSTALLATION_NAME`, `BRAND_NAME`, the
   brand/legal URLs and the logo paths back to Chatwoot's values. Without the
   folder, the job doesn't exist, and the Zasmate rows persist.
3. **Fewer paid-only surfaces.** Captain, SLA, custom roles, Calls and SAML live
   in `enterprise/`. Without it they aren't in the product at all, instead of
   being hidden by `Custom::DashboardController`.

## Why `DISABLE_ENTERPRISE=true` is not enough here

`ChatwootApp.extensions` returns `%w[enterprise custom]` whenever `custom/`
exists (upstream `lib/chatwoot_app.rb`), and `prepend_mod_with` walks that list.
`config/application.rb` eager-loads `enterprise/app/**` unconditionally. So on
this fork every `Enterprise::` overlay, including the nightly reconcile, loads
even with `DISABLE_ENTERPRISE=true`. Only an image without the folder is MIT-only.

## What the fork used from enterprise, and what replaced it

| Enterprise piece | Used for | Replacement |
| --- | --- | --- |
| `Enterprise::Api::V1::AccountsController#limits` (`GET /enterprise/api/v1/accounts/:id/limits`) | the dashboard quota UI (`useQuota`, at-cap states, the agentic-AI banner) | `Custom::AccountLimitsController#show`, on the **same path**, drawn by `config/initializers/custom_routes.rb` (`routes.prepend`), so the frontend is unchanged and the route works whether or not the folder is present |
| `Enterprise::Account::PlanUsageAndLimits` | `limits` schema | already replaced by `Custom::Account::PlanUsageAndLimits`, which hangs on upstream's own `Account.prepend_mod_with('Account::PlanUsageAndLimits')` in `app/models/account.rb` |

Everything else in the fork's quota layer (`Custom::EntitlementService`,
`QuotaGuard`, `QuotaEnforcement`) reads the core `accounts.limits` column and
never depended on enterprise.

## How to build

```sh
scripts/build-ce-image.sh <sha>      # last line must be: CE IMAGE OK: mesh-crm:<sha>
```

The script clones fresh, runs the fork policy check, strips `enterprise/` and
`spec/enterprise/`, labels the edition `ce`, builds, and fails if
`/app/enterprise` exists in the image. Then continue with agentic-str
`docs/guide/06-releasing-the-inbox` from "Push it to GHCR".

## After the first MIT-only release

Apply the branding rows once (`REBRAND_PRODUCTION.md`). They now persist, and
`python3 scripts/fork-policy/check.py --live https://inbox.zasmate.com` should
print `RESULT: ok to ship` the next day as well. That's the proof the nightly
reset is gone.

## Existing data

Tables that only enterprise used (Captain, SLA, custom roles, …) stay in the
database, untouched and unread. Nothing is migrated or deleted. Rolling back to
an image with `enterprise/` would load them again, and would also bring back
the nightly branding reset.

## Tests

Run the fork suite against a tree without the folder, the same way the build does:

```sh
git worktree add --detach /tmp/mesh-ce HEAD && cp .env /tmp/mesh-ce/ && rm -rf /tmp/mesh-ce/enterprise /tmp/mesh-ce/spec/enterprise
cd /tmp/mesh-ce && docker compose -p meshce -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c "bundle install && bundle exec rails db:schema:load && bundle exec rails zeitwerk:check && bundle exec rspec spec/custom"
```
