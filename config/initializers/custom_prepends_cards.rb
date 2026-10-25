# Fork: card messages (content_type `cards`) on Messenger and Instagram go out as a generic
# template after their text, instead of as the text alone. Same mechanism and
# reasoning as config/initializers/custom_prepends.rb. See
# custom/app/services/custom/generic_template_cards_send.rb.
Rails.application.config.to_prepare do
  # Instagram::BaseSendService covers both Instagram Login and Instagram
  # through a Page (Instagram::Messenger::SendOnInstagramService).
  [Facebook::SendOnFacebookService, Instagram::BaseSendService].each do |target|
    Custom::PrependOnce.call(target, Custom::GenericTemplateCardsSend)
  end
end
