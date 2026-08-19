# Is this account one the control plane runs — i.e. one where meta-saas's AI
# agent is the only thing that may put a message in front of a customer?
#
# Shared by the two model overlays that enforce that rule (`Custom::AutomationRule`
# and `Custom::Campaign`). It lives here rather than being written twice because
# the two guards MUST agree: an account where automations may not reply but
# campaigns may is not a coherent policy, it is a bug, and two copies of a
# predicate are how that happens.
#
# **How the account is detected, and why by this signal.** Through
# `accounts.limits`, which only a platform plan sync ever writes — specifically
# `agent_bots: 0`, the control plane's own machine-readable statement that
# nothing but its agent replies here (agentic-str `chatwoot-limits.ts` projects
# it from `plan.maxAgentBots`, which every plan sets to 0). A stock Chatwoot
# account has no `limits` at all, so it is untouched and keeps behaving exactly
# as upstream intends.
#
# That scoping is the premise, not a softening of it: "automations and campaigns
# must not reply" follows from "an AI agent owns the replies on this account",
# and this is the only place that fact is recorded. It also keeps the fork's
# standing rule intact — a fork guard must not red the upstream suite (see
# `Custom::EntitlementService#limit_for`, scoped the same way for the same
# reason).
module Custom::Concerns::PlatformReplyAuthority
  extend ActiveSupport::Concern

  private

  def platform_reserves_replies?
    return false if account.blank?

    limits = account[:limits].to_h
    limits.key?('agent_bots') && limits['agent_bots'].to_i.zero?
  end
end
