# WhatsApp phone registration: recover from a two-step PIN we do not hold.
#
# Upstream registers with the PIN stored on the channel, or a random new one.
# Meta keeps a number's PIN after `/deregister`, so the PIN is lost whenever the
# channel that stored it is gone while the number keeps it: deleting an inbox
# (WebhookTeardownService deregisters, the row and its PIN are destroyed), or a
# signup cut off between `/register` and `store_pin`. Every later `/register`
# then fails with (#133005) PIN Mismatch. Upstream logs that and continues, so
# the inbox looks connected while Meta delivers nothing; the only way out was
# turning two-step verification off by hand in WhatsApp Manager.
#
# On that one error code this sets a fresh PIN through the API (which needs no
# old PIN, see Custom::WhatsappTwoStepPin), registers again with it, and stores
# it like upstream does. Any other failure keeps upstream behaviour unchanged.
# The PIN is never logged.
#
# ⚠ Meta sets a PIN only on a REGISTERED number: after an inbox delete the
# number is deregistered and the reset fails with (#133010) "The account is not
# registered" (seen in production 2026-10-17). That case is covered earlier by
# Custom::WhatsappPinMemory, which registers with the PIN the deleted inbox set.
# This recovery remains for a number that is still registered under a PIN we
# never stored (e.g. a signup cut off before `store_pin`).
#
# Prepended onto Whatsapp::WebhookSetupService from
# config/initializers/custom_prepends.rb, so the upstream file is not edited.
# Spec: spec/custom/services/custom/whatsapp_registration_pin_recovery_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::WhatsappRegistrationPinRecovery
  PIN_MISMATCH = /\(#133005\)/

  private

  def register_phone_number
    super
    recover_from_pin_mismatch if registration_error&.message&.match?(PIN_MISMATCH)
  end

  def recover_from_pin_mismatch
    phone_number_id = @channel.provider_config['phone_number_id']
    pin = SecureRandom.random_number(900_000) + 100_000

    @api_client.set_two_step_verification_pin(phone_number_id, pin)
    @api_client.register_phone_number(phone_number_id, pin)
    store_pin(pin)
    @registration_error = nil
    Rails.logger.info("[WHATSAPP] Phone #{phone_number_id} registered after resetting a two-step PIN this channel did not hold")
  rescue StandardError => e
    @registration_error = e
    Rails.logger.warn("[WHATSAPP] Two-step PIN recovery failed for phone #{phone_number_id}: #{e.message}")
  end
end
