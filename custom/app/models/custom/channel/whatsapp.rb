# Fork overlay for Channel::Whatsapp — keeps Meta app secrets out of the inbox
# API payload, and keeps them in the database when a client writes the redacted
# payload back.
#
# ## Why
#
# `app/views/api/v1/models/_inbox.json.jbuilder` serializes the WhatsApp
# channel's ENTIRE `provider_config` jsonb to any account **administrator** —
# the role every vendor on this platform is provisioned into — on both `index`
# and `show`. `provider_config` is a free-form bag, and four of its keys are the
# ones `MetaTokenVerifyConcern` verifies inbound Meta webhook signatures with
# (`app_secret`, `app_secret_key`, `client_secret`, `api_secret`). A Meta app
# secret is an APP-wide credential, not a per-inbox one: whoever holds it can
# forge `X-Hub-Signature-256` for every inbox on the same Meta app — every
# other tenant included — and can mint `appsecret_proof` for Graph calls.
#
# Today this platform sidesteps the disclosure by never writing an app secret
# into `provider_config` at all, which is precisely why the sibling overlay
# `Custom::Webhooks::WhatsappController` has to fall back to the
# installation-wide `WHATSAPP_APP_SECRET`. That is a convention, not a control:
# any operator (or a future upstream feature) that puts a per-channel secret
# there publishes it to every tenant admin with one GET. This makes it a
# control.
#
# `api_key` is deliberately NOT redacted. It is the channel's own send token,
# scoped to that one WABA, and the dashboard reads it back (Configuration page,
# manual-migration dialog); dropping it would break vendor-facing flows without
# protecting a shared credential.
#
# ## The write-back half (`before_save`)
#
# Redaction alone would introduce a silent data-loss bug, because the dashboard
# edits `provider_config` by read-modify-write:
#
#   payload.channel.provider_config = { ...this.inbox.provider_config,
#                                       api_key: this.whatsAppInboxAPIKey }
#   — app/javascript/.../settingsPage/ConfigurationPage.vue
#
# `Channel#provider_config` is a jsonb column that the inbox controller replaces
# WHOLESALE, so an admin who rotates the API key would post back the redacted
# hash and erase a stored `app_secret` — turning webhook verification off for
# that channel without a single error. So: a secret key that is ABSENT from an
# incoming write is carried over from the stored row. Sending the key with a
# blank value still clears it, which keeps removal possible and explicit.
#
# Hooked on the `Channel::Whatsapp.prepend_mod_with('Channel::Whatsapp')` line
# upstream already ships at the bottom of app/models/channel/whatsapp.rb, so the
# only upstream edit this behavior needs is the one-line call site in the
# jbuilder view (views cannot be prepended).
module Custom::Channel::Whatsapp
  def self.prepended(base)
    base.before_save :retain_stored_meta_app_secrets
  end

  # The provider_config an API client may see. Same hash, minus the Meta app
  # secrets. Called from `_inbox.json.jbuilder`.
  def provider_config_without_app_secrets
    provider_config.to_h.except(*meta_app_secret_keys)
  end

  private

  # Deliberately the controller concern's list rather than a copy of it: these
  # two must never disagree about what counts as an app secret, because the
  # difference between the lists is exactly the set of secrets that get
  # verified against but published anyway.
  def meta_app_secret_keys
    MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS
  end

  # Carries stored app secrets across a write that omits them — see "The
  # write-back half" above. `before_save` rather than `before_validation` so it
  # also covers the `save!(validate: false)` paths (voice toggles).
  def retain_stored_meta_app_secrets
    return unless will_save_change_to_provider_config?

    incoming = provider_config.to_h.stringify_keys
    retained = retainable_meta_app_secrets(incoming)
    return if retained.empty?

    # Only reassign when something is actually carried over, so an ordinary
    # write keeps the exact hash the caller passed.
    self.provider_config = incoming.merge(retained)
  end

  def retainable_meta_app_secrets(incoming)
    stored = provider_config_in_database.to_h.stringify_keys

    meta_app_secret_keys.each_with_object({}) do |key, retained|
      # `key?`, not `present?`: an explicit blank is a deliberate removal.
      next if incoming.key?(key)

      retained[key] = stored[key] if stored[key].present?
    end
  end
end
