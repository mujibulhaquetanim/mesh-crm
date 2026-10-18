# Fork: WhatsApp Custom:: overlays onto upstream classes that ship no
# `prepend_mod_with` hook. Same mechanism and reasoning as
# config/initializers/custom_prepends.rb.
Rails.application.config.to_prepare do
  # Registration: on (#133005) PIN Mismatch, set a fresh two-step PIN through
  # the API and register again, instead of leaving the number Disconnected
  # behind an inbox that reports success. The client gains the PIN call the
  # recovery needs. See
  # custom/app/services/custom/whatsapp_registration_pin_recovery.rb.
  Custom::PrependOnce.call(Whatsapp::FacebookApiClient, Custom::WhatsappTwoStepPin)
  Custom::PrependOnce.call(Whatsapp::WebhookSetupService, Custom::WhatsappRegistrationPinRecovery)

  # PIN memory: a re-added number registers with the PIN its deleted inbox set,
  # because after a delete the number is deregistered and the API can no longer
  # reset it (#133010). See custom/app/services/custom/whatsapp_pin_memory.rb.
  Custom::PrependOnce.call(Whatsapp::WebhookSetupService, Custom::WhatsappPinMemory)
end
