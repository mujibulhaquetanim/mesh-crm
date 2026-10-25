# Sends a `cards` message to Messenger as a generic template (a swipeable row
# of cards) instead of dropping its items. Upstream's send services deliver a
# cards message as its text alone; neither has a cards branch.
#
# `super` sends the text (and any attachments) exactly as upstream does; the
# template goes LAST. Upstream stores the mid of the last part as `source_id`,
# and the inbox recognises the echo of that part as its own, so the cards'
# echo is never mistaken for a reply someone typed on the phone.
#
# When Meta refuses the template, the customer gets "title: url" lines
# instead, and the message is put back to `sent` once they are delivered.
#
# Prepended from config/initializers/custom_prepends_cards.rb, so no upstream
# file is edited. Mapping: Custom::GenericTemplateCards. Spec:
# spec/custom/services/custom/generic_template_cards_send_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::GenericTemplateCardsSend
  private

  def perform_reply
    super
    send_generic_template if message.content_type == 'cards'
  end

  def send_generic_template
    elements = Custom::GenericTemplateCards.elements(message.content_attributes['items'])
    return if elements.empty?

    template = { attachment: { type: 'template', payload: { template_type: 'generic', elements: elements } } }
    send_cards_fallback unless deliver_cards(template)
  rescue StandardError => e
    Rails.logger.warn("GenericTemplateCards: template failed on inbox #{inbox.id}: #{e.class}")
    send_cards_fallback
  end

  def send_cards_fallback
    text = Custom::GenericTemplateCards.fallback_text(message.content_attributes['items'])
    return if text.blank?

    Messages::StatusUpdateService.new(message, 'sent').perform if deliver_cards({ text: text })
  end

  # The Meta message id, or nil when Meta refused it.
  def deliver_cards(payload)
    params = merge_human_agent_tag({ recipient: { id: contact.get_source_id(inbox.id) }, message: payload })
    result = deliver_message(params)
    mid = result&.dig('message_id')
    if mid.blank?
      Rails.logger.warn("GenericTemplateCards: Meta refused a send on inbox #{inbox.id}: #{result&.dig('error', 'code')}")
      return nil
    end

    message.update!(source_id: mid)
    mid
  end
end
