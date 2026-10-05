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

  # ## Manual setup must use a token from the installation's Meta app
  #
  # Meta signs each webhook delivery with the secret of the app that owns the
  # WABA subscription, and manual setup subscribes the app the TOKEN belongs to
  # (`Whatsapp::WebhookSetupService#setup_webhook`). Once the installation has a
  # `WHATSAPP_APP_SECRET`, `Custom::Webhooks::WhatsappController` requires a
  # signature it can verify, and on a channel with no secret of its own that
  # installation secret is the only candidate. So a token from any other Meta
  # app produced an inbox that answered every inbound message with a bare 401,
  # while the inbox UI showed nothing at all.
  #
  # This refuses that setup instead, through upstream's own credential
  # validation, so both setup paths (the classic form and Manual V2's
  # `create!`) show the message, and so the factory's
  # `validate_provider_config: false` switch covers it like every other remote
  # credential check.
  #
  # Fails closed: `debug_token` answers only for a token from the same app as
  # the app token asking, so a token is accepted only when Meta positively names
  # the installation app. Not checked when the channel carries its own app
  # secret (verification then has a matching candidate), for embedded signup
  # (the installation app issued that token itself), when the token is
  # unchanged, or when the installation has no app secret (upstream behavior).
  TOKEN_APP_ERROR =
    'access token could not be confirmed as coming from the Meta app this installation verifies WhatsApp ' \
    'webhooks with. A token from a different Meta app gets every incoming message rejected. ' \
    'Use a token generated from that app.'.freeze

  private

  def validate_provider_config
    super
    return if errors[:provider_config].any?
    return unless token_app_check_required?

    token_app_id, reason = token_app_verdict
    return if reason.nil?

    log_token_app_refusal(token_app_id, reason)
    errors.add(:provider_config, TOKEN_APP_ERROR)
  end

  def token_app_check_required?
    provider == 'whatsapp_cloud' &&
      provider_config['source'] != 'embedded_signup' &&
      GlobalConfigService.load('WHATSAPP_APP_SECRET', nil).present? &&
      !carries_own_meta_app_secret? &&
      provider_config_in_database.to_h['api_key'] != provider_config['api_key']
  end

  # Present on this write, or stored and about to be carried over by
  # `retain_stored_meta_app_secrets` (which runs after validation).
  def carries_own_meta_app_secret?
    incoming = provider_config.to_h.stringify_keys
    incoming.slice(*meta_app_secret_keys).values.any?(&:present?) || retainable_meta_app_secrets(incoming).any?
  end

  # [token_app_id, nil] when the token is the installation app's, otherwise
  # [token_app_id_or_nil, reason].
  def token_app_verdict
    installation_app_id = GlobalConfigService.load('WHATSAPP_APP_ID', nil).to_s
    return [nil, 'installation_app_id_missing'] if installation_app_id.blank?

    data = Whatsapp::FacebookApiClient.new.debug_token(provider_config['api_key']).to_h['data'].to_h
    token_app_id = data['app_id'].to_s.presence
    return [token_app_id, 'token_invalid'] unless data['is_valid'] == true
    return [token_app_id, 'foreign_app'] unless token_app_id == installation_app_id

    [token_app_id, nil]
  rescue StandardError => e
    # The class only: the Graph error body is not ours to log verbatim.
    [nil, "lookup_failed:#{e.class.name}"]
  end

  # App ids are public identifiers; the token and the secrets never appear.
  def log_token_app_refusal(token_app_id, reason)
    Rails.logger.warn(
      '[WHATSAPP_TOKEN_APP] refused ' \
      "phone_number=#{phone_number.to_s.inspect} " \
      "account_id=#{account_id || 'none'} " \
      "token_app_id=#{token_app_id.to_s.inspect} " \
      "reason=#{reason}"
    )
  end

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
