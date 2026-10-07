# HUMAN_AGENT message tag: never on a platform-managed sender.
#
# Meta allows the tag only on a reply a person wrote, sent after the 24-hour
# window. Upstream's Facebook::HumanAgentTagHelpers decides "a person wrote it"
# with `message.sender.is_a?(User)`. Platform-managed account_users are Users
# too, and one of them is the identity automated replies are posted as (see
# Custom::PlatformManagedUsers), so with ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT /
# ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT on, an automated reply that went out
# after the window would be sent as a human one. This narrows the check to
# senders that are not platform-managed in the message's account.
#
# Prepended onto the two classes that include the helper
# (Facebook::SendOnFacebookService, Instagram::BaseSendService) from
# config/initializers/custom_prepends.rb, so the upstream files are not edited.
# Spec: spec/custom/services/custom/human_agent_tag_platform_guard_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::HumanAgentTagPlatformGuard
  private

  def human_agent_tag_applicable?
    super && !platform_managed_sender?
  end

  def platform_managed_sender?
    message.account.account_users.exists?(user_id: message.sender_id, platform_managed: true)
  end
end
