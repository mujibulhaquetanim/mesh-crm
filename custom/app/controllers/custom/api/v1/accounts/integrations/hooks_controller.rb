module Custom::Api::V1::Accounts::Integrations::HooksController
  def self.prepended(base)
    base.include Custom::Concerns::QuotaEnforcement
    base.include Custom::Concerns::PlatformActor
    base.include Custom::Concerns::VendorFeatureGuard
    base.before_action :refuse_blocked_integration_to_vendors, only: [:create, :update, :process_event]
    base.before_action :check_integrations_quota, only: [:create]
  end

  private

  # Creating, re-enabling or invoking an AI integration (OpenAI reply
  # suggestions, Dialogflow) is refused. `destroy` stays open so a vendor can
  # remove one that existed before this policy. See Custom::VendorFeaturePolicy.
  def refuse_blocked_integration_to_vendors
    return if platform_actor?

    app_id = action_name == 'create' ? params.dig(:hook, :app_id) : @hook.app_id
    refuse_platform_managed_feature if Custom::VendorFeaturePolicy.blocked_integration_app?(app_id)
  end

  def check_integrations_quota
    check_quota(:integrations)
  end
end
