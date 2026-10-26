# Maps the items of a `cards` message to WhatsApp Cloud interactive messages:
# - an interactive media CAROUSEL (2 to 10 swipeable cards, each with a photo,
#   the name and description, and a button), the main path;
# - one "call to action URL" message per product, the fallback.
#
# Limits are WhatsApp's (it refuses rather than clips): message body 1024
# characters, carousel card body 160 characters with at most 2 line breaks,
# button text 20. A carousel card must have a photo. Items are read with Custom::GenericTemplateCards.usable (an
# item needs a title and a link) and clipped with its grapheme-safe `clip`.
#
# Used by Custom::WhatsappCardsSend. Spec:
# spec/custom/services/custom/whatsapp_cards_send_spec.rb.
module Custom::WhatsappProductCards
  MAX_CARDS = 10
  MAX_BODY = 1024
  MAX_BUTTON_TEXT = 20
  MIN_CAROUSEL_CARDS = 2
  MAX_CAROUSEL_CARDS = 10
  MAX_CARD_BODY = 160
  # The carousel body is required; this stands in when the text went on its own.
  CAROUSEL_LEAD = '👇'.freeze

  module_function

  # [item, first link] for each card to send, in order.
  def cards(items)
    Custom::GenericTemplateCards.usable(items).first(MAX_CARDS).map { |item, links| [item, links.first] }
  end

  # The `interactive` carousel for `cards` ([item, link, photo] each, every
  # photo present), with `text` as its body (CAROUSEL_LEAD when blank).
  def carousel(text, cards)
    {
      type: 'carousel',
      body: { text: text.present? ? Custom::GenericTemplateCards.clip(text, MAX_BODY) : CAROUSEL_LEAD },
      action: { cards: cards.each_with_index.map { |(item, link, image), index| carousel_card(item, link, image, index) } }
    }
  end

  def carousel_card(item, link, image, index)
    {
      card_index: index,
      type: 'cta_url',
      header: { type: 'image', image: image },
      body: { text: one_line_body(item, MAX_CARD_BODY) },
      action: { name: 'cta_url', parameters: button(item, link) }
    }
  end

  # "*Name*", then the description on one line: never more than 1 line break.
  def one_line_body(item, max)
    title = item[:title].to_s.gsub(/\s+/, ' ').strip.delete('*')
    about = item[:description].to_s.gsub(/\s+/, ' ').strip
    Custom::GenericTemplateCards.clip(about.empty? ? "*#{title}*" : "*#{title}*\n#{about}", max)
  end

  def button(item, link)
    { display_text: Custom::GenericTemplateCards.clip(link[:text].presence || item[:title], MAX_BUTTON_TEXT),
      url: link[:uri] }
  end

  # The `interactive` object for one card; `header_image` is a media object
  # ({ 'id' => … }) or nil for a card sent without its photo.
  def interactive(item, link, header_image)
    payload = {
      type: 'cta_url',
      body: { text: body_text(item) },
      action: { name: 'cta_url', parameters: button(item, link) }
    }
    payload[:header] = { type: 'image', image: header_image } if header_image.present?
    payload
  end

  # "*Name*" in WhatsApp bold, then the description on its own line.
  def body_text(item)
    title = item[:title].to_s.strip.delete('*')
    text = item[:description].present? ? "*#{title}*\n#{item[:description].to_s.strip}" : "*#{title}*"
    Custom::GenericTemplateCards.clip(text, MAX_BODY)
  end

  # The wamid of a send, or :refused when WhatsApp answered with an error.
  def wamid_or_refused(response, inbox_id)
    parsed = response.parsed_response
    id = parsed.dig('messages', 0, 'id') if parsed.is_a?(Hash) && parsed['error'].blank?
    return id if response.success? && id.present?

    Rails.logger.warn("WhatsappCardsSend: WhatsApp refused a card message on inbox #{inbox_id}: #{response.body.to_s.truncate(300)}")
    :refused
  end

  def api_version
    GlobalConfigService.load('WHATSAPP_API_VERSION', Whatsapp::MediaUploadService::WHATSAPP_API_VERSION_FALLBACK)
  end

  # The "title: url" lines sent instead of the cards WhatsApp refused.
  def fallback_text(pairs)
    pairs.map { |item, link| "#{item[:title].to_s.strip}: #{link[:uri]}" }.join("\n")
  end
end
