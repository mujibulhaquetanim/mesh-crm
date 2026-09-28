# Fork overlay for Account (upstream's `Account.prepend_mod_with('Account')`).
# Also the namespace of Custom::Account::PlanUsageAndLimits.
module Custom::Account
  # A calling flag on a build that can't place calls reads as off.
  #
  # Voice (Twilio) and WhatsApp calling run entirely on enterprise code: the
  # `Call` model, the calls API and the Twilio voice webhooks all live in
  # enterprise/, and config/routes.rb draws their routes only when that folder
  # exists. Production is built without it (docs/fork/MIT_ONLY.md), yet the
  # platform turns `channel_voice` on for the plans that will sell calling
  # (agentic-str chatwoot-features.ts). With the stored bit on, the dashboard
  # offered a call button in conversations, the WhatsApp "Calls" inbox tab and
  # the Add-inbox call tiles, and every one of them hit a 404.
  #
  # Keyed on whether the Call model is loadable, not on `ChatwootApp.enterprise?`,
  # so the day upstream moves calling into the MIT core the flag starts working
  # again with no fork change (UPSTREAM_SYNC.md §5c). The stored bit is left
  # alone: the platform keeps writing it and it applies once calls can be served.
  def feature_channel_voice?
    Custom::Account.calls_served? && super
  end

  def self.calls_served?
    Object.const_defined?(:Call)
  end
end
