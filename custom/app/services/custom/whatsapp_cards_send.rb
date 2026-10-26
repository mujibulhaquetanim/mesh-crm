# Sends a `cards` message on a WhatsApp Cloud inbox as its text followed by one
# interactive "call to action URL" message per product (photo, name,
# description, a button to the product page). Upstream sends a cards message
# as its text alone.
#
# Same rules as the Messenger/Instagram overlay (Custom::GenericTemplateCardsSend):
# - the text goes first and its wamid stays the message's `source_id` (a
#   cards-only message keeps its first card's), so delivery and read
#   receipts keep landing on the message;
# - no cards when the text itself failed: upstream's status and error stay;
# - cards WhatsApp refuses go as one "title: url" text instead; the message is
#   marked failed only when nothing at all reached the customer;
# - no fallback for a card that timed out (WhatsApp may have delivered it).
#
# Photos are uploaded first (Custom::WhatsappCardMedia); a card whose photo
# cannot be uploaded goes without it. Only the Cloud provider: a 360dialog
# inbox keeps upstream's text-only send.
#
# Prepended from config/initializers/custom_prepends_cards.rb. Mapping:
# Custom::WhatsappProductCards. Spec:
# spec/custom/services/custom/whatsapp_cards_send_spec.rb.
module Custom::WhatsappCardsSend
  def send_message(phone_number, message)
    cards = cards_to_send(message)
    return super if cards.nil?

    text_id = nil
    if message.outgoing_content.present?
      text_id = super
      return nil if text_id.blank?
    end
    deliver_cards(phone_number, message, cards, text_id)
  end

  private

  # The cards of a `cards` message with no attachments, or nil: upstream's.
  def cards_to_send(message)
    return unless message.content_type == 'cards' && message.attachments.blank?

    Custom::WhatsappProductCards.cards(message.content_attributes['items']).presence
  end

  # The wamid to store: the text's, else the first card's, else the fallback's.
  def deliver_cards(phone_number, message, cards, text_id)
    sent_ids, refused = send_product_cards(phone_number, cards)
    fallback_id = refused.any? ? send_cards_fallback(phone_number, refused) : nil
    id = text_id.presence || sent_ids.first || fallback_id
    cards_failed(message) if id.blank?
    id
  end

  # [wamids of the cards WhatsApp accepted, [item, link] pairs it refused].
  def send_product_cards(phone_number, cards)
    media = Custom::WhatsappCardMedia.new(whatsapp_channel)
    sent = []
    refused = []
    cards.each do |item, link|
      image = item[:media_url].present? ? media.media_for(item[:media_url]) : nil
      id = post_card(phone_number, Custom::WhatsappProductCards.interactive(item, link, image))
      id == :refused ? refused << [item, link] : (sent << id if id)
    end
    [sent, refused]
  end

  # The wamid, :refused when WhatsApp answered with an error, or nil after a
  # timeout (it may have been delivered, so no fallback for it).
  def post_card(phone_number, interactive)
    response = HTTParty.post(
      "#{phone_id_path(cards_api_version)}/messages",
      headers: api_headers,
      body: { messaging_product: 'whatsapp', **recipient_params(phone_number), type: 'interactive',
              interactive: interactive }.to_json
    )
    wamid_or_refused(response)
  rescue Net::ReadTimeout, Net::OpenTimeout => e
    Rails.logger.warn("WhatsappCardsSend: no answer for a card on inbox #{whatsapp_channel.inbox&.id} (#{e.class}); no fallback")
    nil
  end

  def send_cards_fallback(phone_number, pairs)
    response = HTTParty.post(
      "#{phone_id_path(cards_api_version)}/messages",
      headers: api_headers,
      body: { messaging_product: 'whatsapp', **recipient_params(phone_number), type: 'text',
              text: { body: Custom::WhatsappProductCards.fallback_text(pairs) } }.to_json
    )
    id = wamid_or_refused(response)
    id == :refused ? nil : id
  rescue StandardError => e
    Rails.logger.warn("WhatsappCardsSend: fallback failed on inbox #{whatsapp_channel.inbox&.id}: #{e.class}: #{e.message}")
    nil
  end

  def wamid_or_refused(response)
    parsed = response.parsed_response
    id = parsed.dig('messages', 0, 'id') if parsed.is_a?(Hash) && parsed['error'].blank?
    return id if response.success? && id.present?

    Rails.logger.warn("WhatsappCardsSend: WhatsApp refused a card on inbox #{whatsapp_channel.inbox&.id}: #{response.body.to_s.truncate(300)}")
    :refused
  end

  # Nothing reached the customer: neither text, cards nor the fallback.
  def cards_failed(message)
    message.update!(status: :failed, external_error: 'The product cards could not be delivered')
  end

  def cards_api_version
    GlobalConfigService.load('WHATSAPP_API_VERSION', Whatsapp::MediaUploadService::WHATSAPP_API_VERSION_FALLBACK)
  end
end
