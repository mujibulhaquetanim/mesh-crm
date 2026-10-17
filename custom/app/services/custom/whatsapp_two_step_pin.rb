# WhatsApp Cloud API: set a phone number's two-step verification PIN.
#
# `POST /{phone_number_id}` with `{ pin }` sets a new PIN without the old one
# (Meta: "If you don't have your PIN, you can change your PIN using the API").
# Upstream's client has no such call; Custom::WhatsappRegistrationPinRecovery
# needs it to recover from a PIN it never stored.
#
# Prepended onto Whatsapp::FacebookApiClient from
# config/initializers/custom_prepends.rb, so the upstream file is not edited.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::WhatsappTwoStepPin
  def set_two_step_verification_pin(phone_number_id, pin)
    response = HTTParty.post(
      "#{Whatsapp::FacebookApiClient::BASE_URI}/#{@api_version}/#{phone_number_id}",
      headers: request_headers,
      body: { pin: pin.to_s }.to_json
    )

    handle_response(response, 'Two-step verification PIN update failed')
  end
end
