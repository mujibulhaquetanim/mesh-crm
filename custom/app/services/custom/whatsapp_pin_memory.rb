# WhatsApp registration: reuse the PIN this installation last set on a number.
#
# Upstream picks the channel's stored PIN or a random new one. A re-added
# number has a new channel with no PIN, while Meta still holds the PIN the
# deleted channel set, so the random one fails with (#133005) and, the number
# being deregistered, cannot be reset through the API either (#133010). Before
# falling back to a random PIN this asks Custom::WhatsappNumberPin, and every
# PIN the service stores is remembered there too, so the next channel for the
# same number registers with it.
#
# Prepended onto Whatsapp::WebhookSetupService from
# config/initializers/custom_prepends_whatsapp.rb, so the upstream file is not
# edited. Spec: spec/custom/services/custom/whatsapp_pin_memory_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::WhatsappPinMemory
  private

  def fetch_or_create_pin
    return super if @channel.provider_config['verification_pin'].present?

    Custom::WhatsappNumberPin.recall(@channel.provider_config['phone_number_id']) || super
  end

  def store_pin(pin)
    super
    Custom::WhatsappNumberPin.remember(@channel.provider_config['phone_number_id'], pin)
  end
end
