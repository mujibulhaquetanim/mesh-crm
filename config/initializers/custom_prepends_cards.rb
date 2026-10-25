# Fork: card messages (content_type `cards`) on Messenger go out as a generic
# template after their text, instead of as the text alone. Same mechanism and
# reasoning as config/initializers/custom_prepends.rb. See
# custom/app/services/custom/generic_template_cards_send.rb.
Rails.application.config.to_prepare do
  Custom::PrependOnce.call(Facebook::SendOnFacebookService, Custom::GenericTemplateCardsSend)
end
