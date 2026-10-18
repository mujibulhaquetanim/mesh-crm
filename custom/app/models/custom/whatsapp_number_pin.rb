# The last two-step verification PIN this installation set on a WhatsApp
# number, kept after the channel that set it is gone.
#
# Upstream keeps the PIN only in `channel_whatsapp.provider_config`. Deleting a
# WhatsApp inbox deregisters the number at Meta (WebhookTeardownService), but
# Meta keeps the number's PIN, so the next signup for the same number fails
# `/register` with (#133005) PIN Mismatch, and Meta refuses to set a new PIN on
# a number that is not registered (#133010). Remembering the PIN here, keyed by
# Meta's phone number id, lets the re-added number register again. Written by
# Custom::WhatsappPinMemory and Custom::Channel::Whatsapp#teardown_webhooks;
# read only server-side, never serialized.
#
# Compact class form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
class Custom::WhatsappNumberPin < ApplicationRecord
  self.table_name = 'custom_whatsapp_number_pins'

  encrypts :pin if Chatwoot.encryption_configured?

  validates :phone_number_id, presence: true, uniqueness: true
  validates :pin, presence: true

  def self.remember(phone_number_id, pin)
    return if phone_number_id.blank? || pin.blank?

    record = find_or_initialize_by(phone_number_id: phone_number_id.to_s)
    record.update!(pin: pin.to_s)
  end

  def self.recall(phone_number_id)
    return if phone_number_id.blank?

    find_by(phone_number_id: phone_number_id.to_s)&.pin
  end
end
