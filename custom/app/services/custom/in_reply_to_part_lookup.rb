# A customer's "Reply" to one part of a multi-part message still links to it.
#
# Upstream's Messages::InReplyToMessageBuilder finds the quoted message by
# `source_id` only. One outgoing message can go out as several Meta messages
# (text, each attachment, product cards) and keeps only one of their ids there,
# so a reply to any other part found nothing, and upstream then set BOTH
# `in_reply_to` and `in_reply_to_external_id` to nil. The reply reached the
# platform API as a plain message: the AI could not even tell it was a reply,
# and answered about the last product in the chat (agentic-str ts/809).
#
# Two changes, both only when upstream's own lookup found nothing:
#
# 1. Look the id up in the message's recorded parts (Custom::MetaPartIds).
# 2. Still nothing, on a CUSTOMER message: keep the quoted provider id instead
#    of clearing it. The platform API reads `in_reply_to_external_id` alone as
#    "a reply to something that could not be loaded", which lets the AI ask
#    which message the customer means rather than guess. Outgoing messages keep
#    upstream's clear: the WhatsApp send uses that field as the reply context
#    it sends to Meta, and an id Meta does not know would fail the send.
#
# Prepended from config/initializers/custom_prepends.rb. Spec:
# spec/custom/services/custom/in_reply_to_part_lookup_spec.rb.
module Custom::InReplyToPartLookup
  private

  def set_in_reply_to_attribute
    super
    return unless @message.incoming?
    return if @message.content_attributes[:in_reply_to].present?
    return if @in_reply_to.present? || @in_reply_to_external_id.blank?

    @message.content_attributes[:in_reply_to_external_id] = @in_reply_to_external_id
  end

  # Upstream calls this twice per save; the result is memoised so the extra
  # lookup runs at most once.
  def in_reply_to_message
    return @in_reply_to_message if defined?(@in_reply_to_message)

    @in_reply_to_message = super || quoted_part_owner
  end

  def quoted_part_owner
    return if @in_reply_to.present?

    Custom::MetaPartIds.owner_of(conversation, @in_reply_to_external_id)
  end
end
