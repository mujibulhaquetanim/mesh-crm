# The dashboard's quota endpoint, served by fork code on the MIT core.
#
# The frontend's `accounts/limits` store action (via `useQuota` and the
# agentic-AI banner) calls GET /enterprise/api/v1/accounts/:account_id/limits.
# Upstream serves that path from `enterprise/`, which this fork does not run in
# production. config/initializers/custom_routes.rb
# prepends the same path to this controller, so the frontend is unchanged and
# the route works with or without the enterprise folder present.
#
# Response: `{ id:, limits: { <resource> => { allowed:, consumed: } } }`, the
# shape `SET_ACCOUNT_LIMITS` merges into the account. `allowed: nil` means
# unlimited, so the UI skips its counters.
class Custom::AccountLimitsController < Api::V1::Accounts::BaseController
  # `agents` counts tenant seats only (platform-managed infrastructure is
  # excluded), matching the create guard and the scoped agents list.
  QUOTA_UI_RESOURCES = (%w[agents inboxes] + Custom::Account::PlanUsageAndLimits::QUOTA_RESOURCES).freeze

  def show
    service = Custom::EntitlementService.new(Current.account)
    limits = QUOTA_UI_RESOURCES.index_with do |resource|
      usage = service.usage(resource)
      { 'allowed' => (usage.limit unless usage.limit >= ChatwootApp.max_limit), 'consumed' => usage.current }
    end
    render json: { id: Current.account.id, limits: limits.merge(agentic_ai_usage_limit) }
  end

  private

  # Agentic-AI usage is enforced by the platform, not here. The control plane
  # writes the cap into limits['agentic_ai'] and the running usage into
  # custom_attributes['agentic_ai_usage']; this only displays it. Absent until a
  # cap is provisioned.
  def agentic_ai_usage_limit
    cap = Current.account[:limits].to_h['agentic_ai']
    return {} if cap.blank?

    { 'agentic_ai' => { 'allowed' => cap.to_i, 'consumed' => Current.account.custom_attributes.to_h['agentic_ai_usage'].to_i } }
  end
end
