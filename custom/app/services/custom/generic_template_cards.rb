# Maps the items of a `cards` message (content_type 5, validated by
# ContentAttributeValidator) to the elements of a Messenger/Instagram generic
# template, and to the plain-text lines sent when Meta refuses the template.
#
# Meta refuses an element past its limits rather than clipping it, so clipping
# happens here: title and subtitle 80 characters, URL button title 20, at most
# 3 buttons per element and 10 elements per template.
#
# Only `link` actions become buttons (`web_url`). A postback button would come
# back as a plain message carrying its title, not its payload (see
# Integrations::Facebook::MessageParser and Webhooks::InstagramEventsJob), so it
# is dropped, and an item with no link left is skipped.
#
# Used by Custom::GenericTemplateCardsSend. Spec:
# spec/custom/services/custom/generic_template_cards_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce`.
module Custom::GenericTemplateCards
  MAX_ELEMENTS = 10
  MAX_TITLE = 80
  MAX_SUBTITLE = 80
  MAX_BUTTONS = 3
  MAX_BUTTON_TITLE = 20

  module_function

  def elements(items)
    usable(items).first(MAX_ELEMENTS).map { |item, links| element(item, links) }
  end

  def fallback_text(items)
    usable(items).map { |item, links| "#{item[:title].strip}: #{links.first[:uri]}" }.join("\n")
  end

  # [item, link actions] for every item with a title and at least one link.
  def usable(items)
    Array(items).filter_map do |raw|
      item = raw.to_h.with_indifferent_access
      links = Array(item[:actions]).map { |a| a.to_h.with_indifferent_access }
                                   .select { |a| a[:type] == 'link' && a[:uri].present? }
      [item, links] if item[:title].present? && links.any?
    end
  end

  def element(item, links)
    element = { title: clip(item[:title], MAX_TITLE) }
    element[:subtitle] = clip(item[:description], MAX_SUBTITLE) if item[:description].present?
    element[:image_url] = item[:media_url] if item[:media_url].present?
    element[:default_action] = { type: 'web_url', url: links.first[:uri] }
    element[:buttons] = links.first(MAX_BUTTONS).map do |link|
      { type: 'web_url', url: link[:uri], title: clip(link[:text].presence || item[:title], MAX_BUTTON_TITLE) }
    end
    element
  end

  # Per character, never per byte, so a Bangla or emoji title is never cut
  # mid code point.
  def clip(text, max)
    text = text.to_s.strip
    text.length > max ? "#{text[0, max - 1]}…" : text
  end
end
