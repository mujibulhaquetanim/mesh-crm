# Sends a `cards` message to Messenger or Instagram as a generic template (a swipeable row
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

  # Returns upstream's result unchanged: callers (and upstream's own specs)
  # read the last send's response from `perform`.
  def perform_reply
    result = super
    send_generic_template if message.content_type == 'cards'
    result
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

  # The text already went, so the customer has the answer; what failed is the
  # product links. Neither silent nor raised: a raise here would fail the job
  # after the text was delivered, so the message is marked failed instead.
  def send_cards_fallback
    text = Custom::GenericTemplateCards.fallback_text(message.content_attributes['items'])
    return if text.blank?

    if deliver_cards({ text: text })
      Messages::StatusUpdateService.new(message, 'sent').perform
    else
      mark_cards_failed
    end
  rescue StandardError => e
    Rails.logger.warn("GenericTemplateCards: fallback failed on inbox #{inbox.id}: #{e.class}")
    mark_cards_failed
  end

  def mark_cards_failed
    Messages::StatusUpdateService.new(message, 'failed', 'The product cards could not be delivered').perform
  end

  # The Meta message id, or nil when Meta refused it.
  def deliver_cards(payload)
    params = merge_human_agent_tag({ recipient: { id: contact.get_source_id(inbox.id) }, message: payload })
    mid = meta_send(params)&.dig('message_id')
    if mid.blank?
      Rails.logger.warn("GenericTemplateCards: Meta refused a send on inbox #{inbox.id}")
      return nil
    end

    message.update!(source_id: mid)
    mid
  end

  # Each class's own transport, returning Meta's parsed response or nil.
  # Messenger: `deliver_message`, NOT `send_message_to_facebook`, which marks
  # the message failed before a fallback could run. Instagram: `send_message`
  # (its `process_response` logs and marks a refusal failed; the fallback
  # puts the status back).
  def meta_send(params)
    is_a?(Facebook::SendOnFacebookService) ? deliver_message(params) : send_message(params)
  end
end
