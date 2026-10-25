# Sends a `cards` message to Messenger or Instagram as a generic template (a
# swipeable row of cards) instead of dropping its items. Upstream's send
# services deliver a cards message as its text alone; neither has a cards
# branch.
#
# `super` sends the text (and any attachments) exactly as upstream does, and
# the template goes LAST, so the customer reads the answer first. Rules:
#
# - The message keeps the TEXT's mid as `source_id` (the template's only when
#   there is no text). On Instagram the inbox drops an echo only when its mid
#   matches `source_id`, and the text echo is the one that would otherwise
#   come back as a duplicate of the reply. Messenger drops its own echoes by
#   app id.
# - No cards when the text itself failed: the message keeps upstream's
#   status and error.
# - Meta refuses the template → "title: url" lines instead. If those fail
#   too, the message is marked failed only when nothing reached the customer;
#   after a delivered text a failed status would invite a Retry, which sends
#   the whole message again.
# - No fallback after a read timeout: Meta may have shown the cards.
# - Instagram's transport posts a form-encoded body, which cannot carry an
#   array of hashes; the template goes as JSON text (Graph accepts a JSON
#   string for an object parameter).
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
    send_generic_template if message.content_type == 'cards' && !message.reload.failed?
    result
  end

  def send_generic_template
    elements = Custom::GenericTemplateCards.elements(message.content_attributes['items'])
    return if elements.empty?

    text_mid = message.source_id
    mid = deliver_cards({ attachment: { type: 'template', payload: { template_type: 'generic', elements: elements } } })
    mid ? keep_mid(text_mid, mid) : send_cards_fallback(text_mid)
  rescue Net::ReadTimeout => e
    Rails.logger.warn("GenericTemplateCards: no answer from Meta for the cards on inbox #{inbox.id} (#{e.class}); no fallback")
    keep_mid(text_mid, nil)
  rescue StandardError => e
    Rails.logger.warn("GenericTemplateCards: template refused on inbox #{inbox.id}: #{e.class}: #{e.message}")
    send_cards_fallback(text_mid)
  end

  def send_cards_fallback(text_mid)
    text = Custom::GenericTemplateCards.fallback_text(message.content_attributes['items'])
    return if text.blank?

    mid = deliver_cards({ text: text })
    return cards_failed(text_mid) unless mid

    keep_mid(text_mid, mid)
    Messages::StatusUpdateService.new(message, 'sent').perform
  rescue StandardError => e
    Rails.logger.warn("GenericTemplateCards: fallback failed on inbox #{inbox.id}: #{e.class}: #{e.message}")
    cards_failed(text_mid)
  end

  # Nothing reached the customer → failed. The text did → keep `sent` (an
  # Instagram refusal has already marked it failed) and log.
  def cards_failed(text_mid)
    if text_mid.present?
      keep_mid(text_mid, nil)
      Rails.logger.warn("GenericTemplateCards: cards and fallback both failed on inbox #{inbox.id}; the text was delivered")
      Messages::StatusUpdateService.new(message, 'sent').perform
    else
      Messages::StatusUpdateService.new(message, 'failed', 'The product cards could not be delivered').perform
    end
  end

  # The text's mid stays the stored one; a cards-only message keeps the cards'.
  # Instagram's `process_response` overwrites `source_id` on every send.
  def keep_mid(text_mid, mid)
    wanted = text_mid.presence || mid
    message.update!(source_id: wanted) if wanted.present? && message.source_id != wanted
  end

  # The Meta message id, or nil when Meta refused it. Messenger's
  # `Bot.deliver` raises a FacebookError for a refusal instead.
  def deliver_cards(payload)
    body = facebook_sender? || !payload.key?(:attachment) ? payload : payload.to_json
    params = merge_human_agent_tag({ recipient: { id: contact.get_source_id(inbox.id) }, message: body })
    meta_send(params)&.dig('message_id').presence
  end

  # Each class's own transport, returning Meta's parsed response or nil.
  # Messenger: `deliver_message`, NOT `send_message_to_facebook`, which marks
  # the message failed before a fallback could run. Instagram: `send_message`
  # (its `process_response` logs and marks a refusal failed).
  def meta_send(params)
    facebook_sender? ? deliver_message(params) : send_message(params)
  end

  def facebook_sender?
    is_a?(Facebook::SendOnFacebookService)
  end
end
