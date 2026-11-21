# Every Meta message id one outgoing Chatwoot message was delivered as.
#
# One Chatwoot message can reach the customer as several Meta messages: on
# Messenger and Instagram its text, then each attachment, then the product-card
# template (Custom::GenericTemplateCardsSend); on WhatsApp its text, then one
# message per card when there is no carousel (Custom::WhatsappCardsSend).
# `Message#source_id` holds ONE of those ids. A customer who uses "Reply" on any
# other part quotes an id no message has, and upstream's
# Messages::InReplyToMessageBuilder then clears the reply link altogether: the
# reply arrives looking like a plain message, and the AI answers about whatever
# came last instead of the part that was quoted.
#
# This keeps the full list in `content_attributes['meta_part_ids']` (no
# migration: `content_attributes` is a JSON column already) so the reply lookup
# (Custom::InReplyToPartLookup) can find the message by any of its parts.
#
# Capped, deduplicated, and only ever appended to. Callers persist the message;
# `add` only changes it in memory.
module Custom::MetaPartIds
  KEY = 'meta_part_ids'.freeze
  # A reply with 10 carousel cards plus text plus photos stays well inside this.
  MAX = 30
  CHANNEL_TYPES = %w[Channel::FacebookPage Channel::Instagram Channel::Whatsapp].freeze

  def self.add(message, *ids)
    ids = ids.flatten.map { |id| id.to_s.strip }.reject(&:empty?)
    return if ids.empty?

    attrs = message.content_attributes || {}
    known = Array(attrs[KEY])
    merged = (known + ids).uniq.last(MAX)
    return if merged == known

    message.content_attributes = attrs.merge(KEY => merged)
  end

  # `Message` stores `content_attributes` through `store …, coder: JSON` in a
  # `json` column, so the row holds a JSON STRING whose text is the object
  # (`json_typeof` = 'string' on production). Unwrap it; an object-shaped row
  # (written around the coder) is read as is.
  ATTRIBUTES_AS_JSONB = <<~SQL.squish.freeze
    (CASE json_typeof(messages.content_attributes)
       WHEN 'string' THEN (messages.content_attributes #>> '{}')::jsonb
       ELSE messages.content_attributes::jsonb
     END)
  SQL

  # The outgoing message in this conversation that was delivered as `external_id`.
  def self.owner_of(conversation, external_id)
    return if conversation.nil? || external_id.blank?

    conversation.messages
                .where(message_type: :outgoing)
                .where("#{ATTRIBUTES_AS_JSONB} -> '#{KEY}' @> jsonb_build_array(CAST(:id AS text))", id: external_id.to_s)
                .order(id: :desc)
                .first
  end

  def self.tracked_channel?(inbox)
    inbox.present? && CHANNEL_TYPES.include?(inbox.channel_type)
  end
end
