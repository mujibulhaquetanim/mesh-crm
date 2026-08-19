# Fork overlay for AutomationRule, resolved through the upstream
# `AutomationRule.prepend_mod_with('AutomationRule')` hook. Two concerns:
#
# 1. **Plan quota on create** — Custom::Concerns::QuotaGuard (see
#    docs/fork/ENTITLEMENTS.md).
#
# 2. **Reply authority** — an automation may not put a message in front of a
#    customer.
#
#    On a meta-saas account the control plane's agent is the ONLY thing that
#    replies (agentic-str ADR-0006). That is why plan sync force-disables
#    Chatwoot Captain (`captain_integration`, `captain_integration_v2`,
#    `captain_v1_action_classifier` — all pushed as explicit `false`) and
#    projects `agent_bots: 0` into `accounts.limits`. `automation_rules` is
#    deliberately NOT projected as zero, because the useful half of automations
#    is routing — `assign_agent`, `assign_team`, `add_label`, `remove_label`,
#    `snooze_conversation`, `resolve_conversation` — and none of that competes
#    with the agent.
#
#    Two actions do compete. `send_message` and `send_attachment` both reach
#    `Messages::MessageBuilder` with `private: false`
#    (AutomationRules::ActionService), i.e. an outgoing message to the customer,
#    fired on the same `message_created` event the platform agent is answering.
#    Left open, a vendor could build by hand precisely the second reply path the
#    Captain flags exist to prevent. So the cap stays non-zero and these two
#    actions are refused.
#
#    `add_private_note` is deliberately still allowed: a private note is
#    internal-only and never reaches the customer.
#
# **Scoped to accounts the control plane actually runs**, via
# `Custom::Concerns::PlatformReplyAuthority#platform_reserves_replies?` — the
# same predicate `Custom::Campaign` uses, so the two cannot drift into an
# incoherent policy where automations may not reply but campaigns may. See that
# concern for how the account is detected and why.
#
# Measured: unconditional, this validation reds 65 of the 116 upstream
# automation examples; scoped, all 116 stay green.
#
# **Refused at save, not dropped at execution.** A rule that saves cleanly and
# then silently never fires is worse than one that refuses to save — the vendor
# gets no signal either way until they notice the message never went out. The
# error names the reason, not just "invalid".
#
# **Only when the action list is being written.** A rule created before this
# guard existed must still be renameable, deactivatable, and deletable —
# otherwise the guard's first effect on a live account is to strand exactly the
# rules it wants removed. Editing a rule's actions is what forces the fix.
# Note the consequence, deliberately accepted here: a pre-existing rule keeps
# firing until someone edits or deletes it. Sweeping those is an operations
# decision (audit `AutomationRule` rows for these action names), not something
# to bury in a validation.
#
# The upstream `actions_attributes` allowlist is intentionally left alone. Both
# actions stay "supported" by the engine — this is a policy refusal specific to
# how meta-saas runs the account, and it deserves its own message rather than
# upstream's generic "not supported".
module Custom::AutomationRule
  # Actions that emit a customer-visible message. Keep in sync with
  # AutomationRules::ActionService — anything there that builds a message with
  # `private: false` belongs in this list.
  CUSTOMER_FACING_ACTIONS = %w[send_message send_attachment].freeze

  def self.prepended(base)
    base.include Custom::Concerns::QuotaGuard
    base.include Custom::Concerns::PlatformReplyAuthority
    base.validate :customer_facing_actions_absent, if: :reply_authority_enforced?
  end

  private

  def reply_authority_enforced?
    actions_being_written? && platform_reserves_replies?
  end

  def actions_being_written?
    new_record? || will_save_change_to_actions?
  end

  def customer_facing_actions_absent
    return if actions.blank?

    blocked = action_names & CUSTOMER_FACING_ACTIONS
    return if blocked.empty?

    errors.add(:actions, I18n.t('errors.automation_rule.customer_facing_action', actions: blocked.uniq.join(', ')))
  end

  # `actions` is jsonb, and Rails does not normalise the hash keys until the
  # row is serialised — so a payload built with symbol keys is still
  # symbol-keyed while validations run. Reading it string-only (as upstream's
  # `json_actions_format` does) would let that shape through.
  def action_names
    Array(actions).filter_map do |action|
      action.with_indifferent_access[:action_name] if action.respond_to?(:with_indifferent_access)
    end
  end
end
