require 'rails_helper'

# A `cards` message's items, as Chatwoot stores them, mapped to the elements of
# a Messenger/Instagram generic template. Meta refuses an element past its
# limits, so the mapping clips instead of passing them through.
RSpec.describe Custom::GenericTemplateCards do
  let(:link) { { 'type' => 'link', 'text' => 'View details', 'uri' => 'https://shop.example/p/1' } }
  let(:item) do
    { 'title' => 'Red Saree', 'description' => 'from 1,200 · S, M',
      'media_url' => 'https://shop.example/i.jpg', 'actions' => [link] }
  end

  describe '.elements' do
    it 'maps an item to an element with title, subtitle, image_url, default_action and one web_url button' do
      expect(described_class.elements([item])).to eq(
        [{
          title: 'Red Saree',
          subtitle: 'from 1,200 · S, M',
          image_url: 'https://shop.example/i.jpg',
          default_action: { type: 'web_url', url: 'https://shop.example/p/1' },
          buttons: [{ type: 'web_url', url: 'https://shop.example/p/1', title: 'View details' }]
        }]
      )
    end

    it 'accepts symbol keys' do
      expect(described_class.elements([item.deep_symbolize_keys]).first[:title]).to eq('Red Saree')
    end

    it 'omits image_url and subtitle when blank' do
      element = described_class.elements([item.merge('description' => ' ', 'media_url' => nil)]).first

      expect(element).not_to have_key(:subtitle)
      expect(element).not_to have_key(:image_url)
    end

    it 'clips title and subtitle to 80 and button title to 20 characters with an ellipsis' do
      long = 'লাল সুতি শাড়ি ' * 10
      element = described_class.elements(
        [item.merge('title' => long, 'description' => long,
                    'actions' => [link.merge('text' => 'বিস্তারিত দেখুন, এখনই অর্ডার করুন')])]
      ).first

      expect(element[:title].length).to eq(80)
      expect(element[:title]).to end_with('…')
      expect(element[:subtitle].length).to eq(80)
      expect(element[:buttons].first[:title].length).to eq(20)
      expect(element[:title]).to be_valid_encoding
    end

    it 'keeps at most 10 elements and 3 buttons' do
      actions = Array.new(5) { |n| link.merge('uri' => "https://shop.example/p/#{n}") }
      elements = described_class.elements(Array.new(12) { item.merge('actions' => actions) })

      expect(elements.size).to eq(10)
      expect(elements.first[:buttons].size).to eq(3)
    end

    it 'drops postback and other non-link actions, and skips an item left with none' do
      postback = { 'type' => 'postback', 'text' => 'Buy', 'payload' => 'BUY_1' }
      elements = described_class.elements(
        [item.merge('actions' => [postback, link]), item.merge('title' => 'Only postback', 'actions' => [postback])]
      )

      expect(elements.size).to eq(1)
      expect(elements.first[:buttons]).to eq([{ type: 'web_url', url: 'https://shop.example/p/1', title: 'View details' }])
    end

    it 'skips an item with a blank title' do
      expect(described_class.elements([item.merge('title' => '  ')])).to eq([])
    end
  end

  describe '.fallback_text' do
    it 'lists "title: uri" per item with a link' do
      other = item.merge('title' => 'Blue Kurta', 'actions' => [link.merge('uri' => 'https://shop.example/p/2')])
      postback_only = item.merge('title' => 'No link', 'actions' => [{ 'type' => 'postback', 'payload' => 'x' }])

      expect(described_class.fallback_text([item, other, postback_only]))
        .to eq("Red Saree: https://shop.example/p/1\nBlue Kurta: https://shop.example/p/2")
    end
  end
end
