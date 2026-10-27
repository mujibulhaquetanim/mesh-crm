# Sends a `cards` message on a WhatsApp Cloud inbox as product cards. Upstream
# sends a cards message as its text alone.
#
# The main path is ONE interactive media carousel: the reply's text as the
# message body and a swipeable card per product (photo, bold name and
# description, a View details button). One message also keeps the reply clear
# of WhatsApp's pair rate limit (1 message per 6 seconds to the same person,
# bursts borrowed from later; error 131056), which text plus seven separate
# messages would spend.
#
# A carousel needs 2 to 10 cards, each with a photo, and a body of at most 1024
# characters. Otherwise, or when refused, the reply goes as its text (upstream)
# then one "call to action URL" message per product; so do photo-less cards.
#
# Same rules as the Messenger/Instagram overlay (Custom::GenericTemplateCardsSend):
# - the stored wamid is the text's, or the carousel's when the text rides in it;
# - no cards when the text itself failed: upstream's status and error stay;
# - cards WhatsApp refuses go as one "title: url" text; the message is marked
#   failed only when nothing at all reached the customer;
# - no fallback after a timeout (WhatsApp may have delivered it).
#
# Photos are uploaded first (Custom::WhatsappCardMedia); a card whose photo
# cannot be uploaded has none. Only the Cloud provider: a 360dialog inbox keeps
# upstream's text-only send.
#
# Prepended from config/initializers/custom_prepends_cards.rb. Mapping:
# Custom::WhatsappProductCards. Spec:
# spec/custom/services/custom/whatsapp_cards_send_spec.rb.
module Custom::WhatsappCardsSend
  def send_message(phone_number, message)
    cards = cards_to_send(message)
    return super if cards.nil?

    cards = with_photos(cards)
    carousel = true
    if text_in_carousel?(message, cards)
      id = post_card(phone_number, Custom::WhatsappProductCards.carousel(message.outgoing_content, pictured(cards)))
      return after_carousel(phone_number, cards, id) unless id == :refused

      carousel = false # refused once: it would be refused again
    end

    text_id = nil
    if message.outgoing_content.present?
      text_id = super
      return nil if text_id.blank?
    end
    deliver_cards(phone_number, message, cards, text_id, carousel: carousel)
  end

  private

  # The cards of a `cards` message with no attachments, or nil: upstream's.
  def cards_to_send(message)
    return unless message.content_type == 'cards' && message.attachments.blank?

    Custom::WhatsappProductCards.cards(message.content_attributes['items']).presence
  end

  # [item, link, photo media object or nil] for each card.
  def with_photos(cards)
    media = Custom::WhatsappCardMedia.new(whatsapp_channel)
    cards.map { |item, link| [item, link, item[:media_url].present? ? media.media_for(item[:media_url]) : nil] }
  end

  def pictured(cards)
    cards.select { |_item, _link, image| image.present? }.first(Custom::WhatsappProductCards::MAX_CAROUSEL_CARDS)
  end

  def text_in_carousel?(message, cards)
    text = message.outgoing_content.to_s
    pictured(cards).size >= Custom::WhatsappProductCards::MIN_CAROUSEL_CARDS &&
      text.present? && text.length <= Custom::WhatsappProductCards::MAX_BODY
  end

  # The carousel went (wamid) or timed out (nil, maybe delivered). Cards that
  # had no photo follow as their own messages.
  def after_carousel(phone_number, cards, id)
    rest = cards - pictured(cards)
    singles = rest.any? ? deliver_singles(phone_number, rest) : []
    # A carousel that timed out may have been delivered: never marked failed.
    id.presence || singles.first
  end

  # After the text (or for a cards-only message): a carousel when it can be
  # one, else one message per card. Returns the wamid to store.
  def deliver_cards(phone_number, message, cards, text_id, carousel:)
    sent_ids, cards, timed_out = carousel ? fallback_carousel(phone_number, cards) : [[], cards, false]
    sent_ids.concat(deliver_singles(phone_number, cards))
    id = text_id.presence || sent_ids.first
    cards_failed(message) if id.blank? && !timed_out
    id
  end

  # [wamids, cards still to send, whether the carousel timed out].
  def fallback_carousel(phone_number, cards)
    return [[], cards, false] if pictured(cards).size < Custom::WhatsappProductCards::MIN_CAROUSEL_CARDS

    id = post_card(phone_number, Custom::WhatsappProductCards.carousel(nil, pictured(cards)))
    return [[], cards, false] if id == :refused

    [[id].compact, cards - pictured(cards), id.nil?]
  end

  # One message per card, then "title: url" lines for those WhatsApp refused.
  # Returns the wamids that went.
  def deliver_singles(phone_number, cards)
    sent = []
    refused = []
    cards.each do |item, link, image|
      id = post_card(phone_number, Custom::WhatsappProductCards.interactive(item, link, image))
      id == :refused ? refused << [item, link] : (sent << id if id)
    end
    sent << send_cards_fallback(phone_number, refused) if refused.any?
    sent.compact
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
    Custom::WhatsappProductCards.wamid_or_refused(response, whatsapp_channel.inbox&.id)
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
    id = Custom::WhatsappProductCards.wamid_or_refused(response, whatsapp_channel.inbox&.id)
    id == :refused ? nil : id
  rescue StandardError => e
    Rails.logger.warn("WhatsappCardsSend: fallback failed on inbox #{whatsapp_channel.inbox&.id}: #{e.class}: #{e.message}")
    nil
  end

  # Nothing reached the customer: neither text, cards nor the fallback.
  def cards_failed(message)
    message.update!(status: :failed, external_error: 'The product cards could not be delivered')
  end

  def cards_api_version
    Custom::WhatsappProductCards.api_version
  end
end
