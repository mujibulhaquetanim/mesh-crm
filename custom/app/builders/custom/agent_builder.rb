# Fixes the agents-quota pre-check inside `AgentBuilder#perform` to count the
# same thing every other quota gate on the platform counts.
#
# Upstream's `can_add_agent?` compares the plan limit against
# `account.account_users.count` — every row, including platform-managed
# infrastructure seats (the control plane's automation service admin behind
# USER_TOKEN and the AI reply identity, ADR-0005/0006). Those seats carry
# `platform_managed: true` and must never consume a tenant's `agents` slot —
# see `Custom::EntitlementService::RESOURCE_COUNTERS[:agents]`
# (custom/app/services/custom/entitlement_service.rb), which already counts
# `account.account_users.where(platform_managed: false)`, and
# `Custom::Api::V1::Accounts::AgentsController#agents`
# (custom/app/controllers/custom/api/v1/accounts/agents_controller.rb), which
# applies the same filter to the list/fetch paths.
#
# `AgentBuilder#can_add_agent?` gates the single-`create` path (invoked from
# `Api::V1::Accounts::AgentsController#create`): a tenant on a 2-agent plan
# with 1 real agent + 1 platform-managed infra user would be blocked from
# adding a second real agent (2/2), even though only one billable seat was in
# use. This override brings that create-time gate in line with the single
# definition of "how many agents does this tenant have" that every other
# enforcement path uses.
#
# It is a SEPARATE fix from `available_agent_count`, the sibling guard on the
# `bulk_create` (bulk-invite) path — that one lives on the controller, not
# this builder, and is fixed in its own overlay,
# custom/app/controllers/custom/api/v1/accounts/agents_controller.rb. Both had
# to be found and fixed independently: neither routes through the other.
#
# Injected via the canonical `AgentBuilder.prepend_mod_with` hook already at
# the bottom of app/builders/agent_builder.rb -- no OSS edit, zero
# upstream-merge conflict.
module Custom::AgentBuilder
  private

  def can_add_agent?
    account.usage_limits[:agents] > account.account_users.where(platform_managed: false).count
  end
end
