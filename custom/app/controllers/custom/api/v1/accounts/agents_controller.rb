# Scopes the tenant-facing agents endpoint to real, billable seats by excluding
# platform-managed `account_users` — the control plane's own infrastructure users
# (the automation service admin behind USER_TOKEN and the AI reply identity,
# ADR-0005/0006). Those carry `platform_managed: true` and must never surface in a
# vendor's Agents settings, count against their `agents` plan slot, or be
# editable/deletable by the tenant (deleting the service admin would destroy the
# account's stored API credential).
#
# This overlay carries THREE independent fixes, because upstream never routes
# all of `index` / `fetch_agent` / the two quota pre-checks through one shared
# method — overriding `agents` alone does NOT reach the quota counters, which
# read `Current.account.account_users` directly:
#
#   - `agents` (below) — the list/fetch finder. Fixes `index` (the list
#     renders only tenant seats) and `fetch_agent` (`agents.find(id)` no
#     longer resolves an infra user → edit/destroy 404).
#   - `available_agent_count` (below) — the `bulk_create` guard
#     (`app/controllers/api/v1/accounts/agents_controller.rb:82,111-113`),
#     reachable from the onboarding bulk-invite UI
#     (`app/javascript/dashboard/api/agents.js`). Fixed here.
#   - `AgentBuilder#can_add_agent?` — the single-`create` guard
#     (`app/builders/agent_builder.rb:40-42`). A **separate class**, fixed in
#     its own overlay, `custom/app/builders/custom/agent_builder.rb`.
#
# All three now agree with `Custom::EntitlementService::RESOURCE_COUNTERS[:agents]`
# (which already filters `platform_managed: false`) and the limits endpoint.
#
# Injected via the canonical `Api::V1::Accounts::AgentsController.prepend_mod_with`
# hook that already ships at the bottom of the upstream controller — no OSS edit,
# zero upstream-merge conflict. `super` inherits whatever the base query becomes on
# future pulls; we only append the filter.
module Custom::Api::V1::Accounts::AgentsController
  private

  def agents
    # NOTE: a distinct ivar is required. `super` memoizes the UNSCOPED relation into
    # `@agents` (`@agents ||= ...` in the base), so reusing `@agents` here would
    # short-circuit on that truthy value and never apply the filter.
    @scoped_agents ||= super.where(account_users: { platform_managed: false })
  end

  def available_agent_count
    Current.account.usage_limits[:agents] - Current.account.account_users.where(platform_managed: false).count
  end
end
