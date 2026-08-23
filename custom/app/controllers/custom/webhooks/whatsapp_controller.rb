# Fork overlay for the WhatsApp webhook endpoint — makes Meta's
# `X-Hub-Signature-256` MANDATORY on a whatsapp_cloud inbox as soon as the
# installation has a secret it could verify with.
#
# ## The hole this closes
#
# Upstream (#14280) added HMAC verification, but only *requires* it when the
# channel itself can prove a secret:
#
#   blank channel                        → required (can't route it anyway)
#   provider != whatsapp_cloud           → not required (360dialog never signs)
#   app secret in provider_config        → required
#   provider_config['source'] == 'embedded_signup' → required
#   otherwise (manual-source cloud)      → NOT REQUIRED
#
# That last line is the problem for this platform. Every WhatsApp inbox we
# provision is a **manual-source whatsapp_cloud** channel, and we deliberately
# do NOT write an app secret into `provider_config` — that column is serialized
# wholesale to every account administrator (see
# `Custom::Channel::Whatsapp`), so putting the platform-wide Meta app secret
# there would hand it to every tenant. The result was the worst of both: the
# installation HAS the secret (as `WHATSAPP_APP_SECRET`, which
# `#meta_app_secrets` already offers as a verification candidate), the endpoint
# is happy to check it — and yet an unsigned POST to
# `/webhooks/whatsapp/<phone_number>` was accepted and queued as a real
# customer message. Anyone who learns a tenant's phone number can inject
# inbound conversation traffic, which the AI agent then answers.
#
# ## What changes
#
#   installation with a global WHATSAPP_APP_SECRET → signature required on
#     EVERY whatsapp_cloud webhook POST, manual source included
#   installation without one                      → upstream behavior, byte for
#     byte (no regression for a stock deployment that never set the config)
#
# The rule is "if we can verify, we must" rather than a new list of conditions,
# so a future upstream that teaches `#meta_app_secrets` about another secret
# source is covered automatically instead of silently reopening this hole.
#
# ## Deliberately NOT touched
#
#   * The `GET` verify handshake (`hub.challenge`). Meta signs only POST
#     deliveries; requiring a signature on the subscription handshake would
#     make the inbox unregisterable. `verify_meta_signature!` is a
#     `before_action ... only: :process_payload` upstream and stays that way.
#   * 360dialog (`provider == 'default'`) inboxes. They are not Meta webhooks
#     and carry no `X-Hub-Signature-256` at all — requiring one would take every
#     360dialog inbox on the installation offline.
#
# Wired from `config/initializers/custom_prepends.rb` (the controller ships no
# `prepend_mod_with` hook of its own), so no upstream file is edited.
module Custom::Webhooks::WhatsappController
  private

  def meta_signature_verification_required?
    # Upstream's own answer first: unresolvable channel, per-channel app secret,
    # or an embedded-signup inbox. Anything it already requires stays required.
    return true if super

    # Unreachable today — upstream requires a signature when the channel can't
    # be resolved, so `super` already returned true. Kept so that an upstream
    # change to that branch fails CLOSED here instead of raising NoMethodError
    # on the next line.
    return true if whatsapp_channel.blank?

    # Reaching here means upstream said "no". Only ONE of its no-cases is safe
    # to keep saying no to: a non-cloud (360dialog) provider, which never signs.
    return false unless whatsapp_channel.provider == 'whatsapp_cloud'

    # ...so what is left is the manual-source cloud inbox. `#meta_app_secrets`
    # is upstream's full list of secrets this request could be verified against;
    # the per-channel entries are necessarily empty here (super would have
    # returned true), which leaves the installation-wide WHATSAPP_APP_SECRET.
    meta_app_secrets.any?(&:present?)
  end

  # Memoized because this override consults the secret list once per request in
  # addition to `#valid_meta_signature?`, and `GlobalConfigService.load` is a
  # Redis round trip (plus a Postgres one on a cache miss) on a hot webhook path.
  # Safe to hold for the request: nothing mutates a config mid-delivery.
  def meta_app_secrets
    @meta_app_secrets ||= super
  end
end
