module Custom::Api::V1::Accounts::WebhooksController
  def self.prepended(base)
    base.include Custom::Concerns::QuotaEnforcement
    base.include Custom::Concerns::PlatformActor
    base.before_action :check_webhooks_quota, only: [:create]
  end

  # Hide platform-managed webhooks from the tenant's own listing.
  #
  # `_webhook.json.jbuilder` renders `json.secret` — by design, since a tenant
  # owns the secret of a webhook they created. But `WebhookPolicy#index?` grants
  # on `administrator?`, and EVERY vendor is provisioned into Chatwoot as an
  # account administrator (the control plane's `handoff-access` mapping), so the
  # orchestrator-ingest webhook's secret was readable by the tenant — from the
  # API and from Settings → Integrations → Webhooks, behind an eye toggle.
  #
  # That secret is the HMAC key our own ingest verifies with. A holder can mint
  # valid `X-Chatwoot-Signature` headers for their account: inject synthetic
  # `message_created` events to burn model tokens against the plan cap, or spoof
  # `conversation_status_changed → resolved` to pull a live conversation back
  # from the human agent mid-handoff.
  #
  # Scoped rather than removing the field: `AGENTS.md` freezes existing response
  # shapes to additive changes only, and a tenant's OWN webhooks must keep
  # showing their secret. What changes is which rows a tenant can see at all —
  # the same fix, in the same shape, that `agents_controller.rb` already applies
  # to platform-managed `account_users`.
  #
  # `super` first, so a future upstream `index` (pagination, ordering, includes)
  # is inherited rather than frozen at today's one-liner.
  def index
    super
    @webhooks = @webhooks.where(platform_managed: false) unless platform_actor?
  end

  private

  # Make a platform-managed webhook unreachable by id for a tenant, so `update`
  # and `destroy` 404 instead of resolving it.
  #
  # Deleting it was the worse half. `Current.account.webhooks.find(id)` resolved
  # any row in the account, and the control plane's repair path is gated on
  # `if (account.hasWebhookSecret) return;` — which reads the STORED ciphertext,
  # not Chatwoot's state. So after a tenant deleted the row, `webhookSecretEnc`
  # was still non-null, the self-heal returned early on every subsequent
  # `ensureAccount`, and the webhook was never re-created: Chatwoot silently
  # stopped delivering and that tenant's AI went dark permanently, with no error
  # on either side. Same incident class as backlog 13, where deleting the
  # platform-managed service admin destroyed the account's stored credential.
  #
  # Raised as `RecordNotFound` (→ 404 via `request_exception_handler`) rather
  # than a 403: a tenant has no legitimate need to learn that a webhook they may
  # not touch exists on their account.
  def fetch_webhook
    super
    return if platform_actor?

    raise ActiveRecord::RecordNotFound if @webhook&.platform_managed?
  end

  def check_webhooks_quota
    # The orchestrator-ingest webhook is platform-managed infrastructure — exempt
    # from tenant entitlements (never counted, never blocked). The exemption is
    # granted ONLY when the acting identity is itself platform-managed (the control
    # plane's service user), never on a tenant-supplied flag, so a tenant admin
    # cannot self-exempt. See docs/fork/adr/0005.
    return if platform_managed_webhook?

    check_quota(:webhooks)
  end

  def platform_managed_webhook?
    platform_actor? && ActiveModel::Type::Boolean.new.cast(params.dig(:webhook, :platform_managed))
  end

  # Strip `platform_managed` from tenant-controllable input: only a platform actor
  # may set it (on create OR update). Anyone else has the key dropped, so the
  # column keeps its `false` default and the record counts against the tenant.
  def webhook_params
    permitted = params.require(:webhook).permit(:inbox_id, :name, :url, :platform_managed, subscriptions: [])
    permitted.delete(:platform_managed) unless platform_actor?
    permitted
  end
end
