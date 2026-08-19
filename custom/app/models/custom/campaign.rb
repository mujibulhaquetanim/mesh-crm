# Fork overlay for Campaign — reply authority, the second half of the rule
# `Custom::AutomationRule` enforces.
#
# A campaign is an automated, customer-facing outbound message that the vendor
# composes and Chatwoot delivers on its own: `one_off` on a WhatsApp/SMS inbox
# is a scheduled bulk send to an audience, and `ongoing` on a Website inbox
# fires at visitors matching `trigger_rules`. Neither passes through the
# platform agent, and both put text in front of a customer.
#
# On a meta-saas account that is the exact thing ADR-0006 reserves: the control
# plane's agent is the only reply authority. Blocking `send_message` on
# automations (see Custom::AutomationRule) while leaving campaigns open would
# close the door and leave the window — a vendor who wanted a second outbound
# path would simply build it here instead, and the automation guard would read
# as theatre.
#
# There is a second, independent reason, and it is the one that bites in
# production: a campaign delivers through Chatwoot directly, so its messages
# never reach our usage metering or audit trail (agentic-str CLAUDE.md §11, §12).
# Every message the platform is accountable for is supposed to be counted and
# replayable. Campaign traffic would be neither — invisible spend on a channel
# the tenant is billed for, and a customer-visible action with no audit row.
#
# **Scoped** through Custom::Concerns::PlatformReplyAuthority, the same
# predicate the automation guard uses. Stock Chatwoot accounts are untouched.
#
# **Refused at save, not dropped at delivery** — same reasoning as the sibling
# guard. A campaign that saves and then silently never sends is worse than one
# that refuses to save: the vendor believes it went out.
#
# **Only when the campaign is being ARMED**, which is deliberately broader than
# the automation guard can be. A campaign has an `enabled` flag, so this can
# refuse re-arming an existing one, not just creation:
#
#   refused  — creating one; re-enabling a disabled one; editing what or where
#              it sends (message, inbox, audience, trigger rules, schedule)
#              while it is enabled
#   allowed  — disabling one; renaming it; editing its description; deleting it
#
# That ordering matters on a live account: the guard's first effect must never
# be to strand the very campaigns someone is trying to switch off. As with
# automations, a pre-existing ENABLED campaign keeps running until someone
# disables or deletes it — sweeping those is an operations decision (audit
# `Campaign.where(enabled: true)` on platform accounts), not something to bury
# in a validation.
#
# Wired through the `Campaign.include_mod_with('Campaign')` line already at the
# bottom of app/models/campaign.rb — `ChatwootApp.extensions` includes `custom`,
# so no upstream edit was needed for this overlay at all.
module Custom::Campaign
  # Attributes that define WHAT gets sent, WHERE, TO WHOM, and WHEN. A change to
  # any of these on an enabled campaign is a send being (re)configured.
  # `enabled` is in the list so flipping it back on is caught; it is the
  # `enabled?` check in #campaign_being_armed? that keeps switching OFF allowed.
  ARMING_ATTRIBUTES = %w[message inbox_id audience trigger_rules scheduled_at enabled].freeze

  def self.included(base)
    base.include Custom::Concerns::PlatformReplyAuthority
    base.validate :campaign_reply_authority, if: :reply_authority_enforced?
  end

  private

  def reply_authority_enforced?
    campaign_being_armed? && platform_reserves_replies?
  end

  def campaign_being_armed?
    return true if new_record?
    # Reads the value this save is about to persist, not the stored one — so
    # disabling a campaign evaluates as `false` here and is always permitted,
    # which is what keeps the guard from trapping the rules it wants removed.
    return false unless enabled?

    ARMING_ATTRIBUTES.any? { |attribute| will_save_change_to_attribute?(attribute) }
  end

  def campaign_reply_authority
    errors.add(:base, I18n.t('errors.campaign.reply_authority_reserved'))
  end
end
