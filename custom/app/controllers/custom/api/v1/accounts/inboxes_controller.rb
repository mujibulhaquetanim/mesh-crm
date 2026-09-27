# Fork overlay: a vendor cannot read or change which agent bot answers an inbox.
#
# `set_agent_bot` is the inbox-level switch that puts a bot in front of every
# new conversation (the "Bot configuration" tab). The rest of the inbox API is
# untouched. See Custom::VendorFeaturePolicy.
module Custom::Api::V1::Accounts::InboxesController
  def self.prepended(base)
    base.include Custom::Concerns::PlatformActor
    base.include Custom::Concerns::VendorFeatureGuard
    base.before_action :refuse_inbox_agent_bot_to_vendors, only: [:agent_bot, :set_agent_bot]
  end

  private

  def refuse_inbox_agent_bot_to_vendors
    refuse_platform_managed_feature unless platform_actor?
  end
end
