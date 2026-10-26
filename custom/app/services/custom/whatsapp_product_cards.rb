# Maps the items of a `cards` message to WhatsApp Cloud interactive
# "call to action URL" messages: one per product, each with the product photo
# as its header, the name and description as its body, and a button that
# opens the product page. WhatsApp has no swipeable row for a session reply,
# so each card is its own message.
#
# Limits are WhatsApp's (it refuses rather than clips): body 1024 characters,
# button text 20. Items are read with Custom::GenericTemplateCards.usable (an
# item needs a title and a link) and clipped with its grapheme-safe `clip`.
#
# Used by Custom::WhatsappCardsSend. Spec:
# spec/custom/services/custom/whatsapp_cards_send_spec.rb.
module Custom::WhatsappProductCards
  MAX_CARDS = 10
  MAX_BODY = 1024
  MAX_BUTTON_TEXT = 20

  module_function

  # [item, first link] for each card to send, in order.
  def cards(items)
    Custom::GenericTemplateCards.usable(items).first(MAX_CARDS).map { |item, links| [item, links.first] }
  end

  # The `interactive` object for one card; `header_image` is a media object
  # ({ 'id' => … }) or nil for a card sent without its photo.
  def interactive(item, link, header_image)
    payload = {
      type: 'cta_url',
      body: { text: body_text(item) },
      action: {
        name: 'cta_url',
        parameters: {
          display_text: Custom::GenericTemplateCards.clip(link[:text].presence || item[:title], MAX_BUTTON_TEXT),
          url: link[:uri]
        }
      }
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

  # The "title: url" lines sent instead of the cards WhatsApp refused.
  def fallback_text(pairs)
    pairs.map { |item, link| "#{item[:title].to_s.strip}: #{link[:uri]}" }.join("\n")
  end
end
