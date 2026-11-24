# Remembers each Meta message id an outgoing message is given as `source_id`.
#
# Upstream's send services overwrite `source_id` once per part they deliver
# (Facebook::SendOnFacebookService#send_message_to_facebook for the text and
# each attachment, Instagram::BaseSendService#process_response likewise), so
# only the last part's id survives. Each assignment passes through here first,
# and Custom::MetaPartIds keeps them all, which is what lets a customer's reply
# to ANY part of the message find it (Custom::InReplyToPartLookup).
#
# Messenger, Instagram and WhatsApp inboxes only; nothing else reads the list.
#
# Loaded through upstream's own `Message.prepend_mod_with('Message')`.
module Custom::Message
  def self.prepended(base)
    base.before_save :remember_meta_part_id, if: :meta_part_id_changed?
  end

  private

  def meta_part_id_changed?
    outgoing? && source_id.present? && will_save_change_to_source_id?
  end

  def remember_meta_part_id
    return unless Custom::MetaPartIds.tracked_channel?(inbox)

    Custom::MetaPartIds.add(self, source_id)
  end
end
