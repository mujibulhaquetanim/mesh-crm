# Fork: the Chatwoot features a vendor may not see or use, because the platform
# already does that job and a second copy would fight it.
#
# Vendors are account ADMINISTRATORS (the platform provisions them that way so
# Chatwoot is their full workspace), so upstream's policies let them do
# everything below. The platform is the only reply authority on an account:
# its agent answers, and a human takes over through handoff.
#
# - **Agent bots.** An inbox with an agent bot parks every new conversation as
#   `pending` and hands it to that bot: a second reply path beside ours, and
#   one that hides conversations from the vendor's human agents. The platform
#   does not use agent bots (its AI replies as a platform-managed agent user),
#   so nothing of ours depends on them.
# - **AI integrations** (`openai`, `dialogflow`). Dialogflow replies to
#   customers on its own; OpenAI rewrites and suggests replies with a model and
#   key the vendor supplies. Both put a second AI in front of the customer.
#   Captain is Chatwoot's third AI; it is switched off per account by the
#   platform (`captain_*: false`), not here.
#
# Two layers enforce this, and this module is the one list both read:
#
# 1. **Hidden** — the platform sends the account feature flag `agent_bots:
#    false`, which removes Settings → Bots
#    and the inbox "Bot configuration" tab. `Custom::Integrations::App` removes
#    the blocked apps from the integrations list.
# 2. **Refused** — the controller overlays return 403 to every identity that is
#    not platform-managed, so the API refuses what the UI hides. Existing
#    Dialogflow hooks stop firing through `Custom::Integrations::Hook#disabled?`.
#
# The platform's own service user stays allowed, keyed off the persisted
# `platform_managed` flag (see Custom::Concerns::PlatformActor), never a request
# parameter.
#
# Adding a feature to this list also means a spec in
# spec/custom/controllers/api/v1/accounts/vendor_feature_policy_spec.rb. The
# pre-rebuild check (scripts/fork-policy/check.py) fails if this file or one of
# its overlays goes missing.
module Custom::VendorFeaturePolicy
  BLOCKED_INTEGRATION_APPS = %w[openai dialogflow].freeze

  ERROR_CODE = 'feature_managed_by_platform'.freeze

  def self.blocked_integration_app?(app_id)
    BLOCKED_INTEGRATION_APPS.include?(app_id.to_s)
  end
end
