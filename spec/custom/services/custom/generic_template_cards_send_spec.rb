require 'rails_helper'

# A `cards` message on a Messenger or Instagram inbox: upstream sends its text
# (and attachments) as before, then the overlay sends the cards as one generic
# template, LAST, so the template's mid is the one stored as `source_id` (the
# echo of the last part is what the inbox recognises as its own).
RSpec.describe Custom::GenericTemplateCardsSend do
  let!(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:items) do
    [
      { title: 'A', description: 'from 1,200', media_url: 'https://shop.example/a.jpg',
        actions: [{ type: 'link', text: 'View details', uri: 'https://a' }] },
      { title: 'B', actions: [{ type: 'link', text: 'View details', uri: 'https://b' }] }
    ]
  end

  def cards_message(inbox, conversation, items: self.items, content: 'Here you go')
    create(:message, message_type: 'outgoing', content: content, content_type: 'cards',
                     content_attributes: { items: items }, sender: agent,
                     inbox: inbox, account: account, conversation: conversation)
  end

  it 'is prepended onto the Messenger send service' do
    expect(Facebook::SendOnFacebookService.ancestors).to include(described_class)
  end

  describe 'on Messenger' do
    # Before the `let!`s: creating the channel subscribes the Page.
    before do
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
      allow(bot).to receive(:deliver) do |params, _options|
        deliveries << params
        responses.shift || { recipient_id: '1', message_id: "mid.#{deliveries.size}" }.to_json
      end
      create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation)
    end

    let(:bot) { class_double(Facebook::Messenger::Bot).as_stubbed_const }
    let(:deliveries) { [] }
    let(:responses) { [] }
    let!(:channel) { create(:channel_facebook_page, account: account) }
    let!(:inbox) { create(:inbox, channel: channel, account: account) }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
    let(:conversation) { create(:conversation, contact: contact, inbox: inbox, contact_inbox: contact_inbox) }

    def perform(message)
      Facebook::SendOnFacebookService.new(message: message).perform
    end

    it 'sends the text, then one generic template, and stores the template mid' do
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(2)
      expect(deliveries[0][:message]).to eq({ text: 'Here you go' })
      payload = deliveries[1].dig(:message, :attachment)
      expect(payload[:type]).to eq('template')
      expect(payload[:payload][:template_type]).to eq('generic')
      expect(payload[:payload][:elements].map { |e| e[:title] }).to eq(%w[A B])
      expect(deliveries[1][:recipient]).to eq({ id: contact_inbox.source_id })
      expect(message.reload.source_id).to eq('mid.2')
    end

    it 'uses the same messaging_type as the text' do
      perform(cards_message(inbox, conversation))

      expect(deliveries.map { |d| d[:messaging_type] }).to eq(%w[RESPONSE RESPONSE])
    end

    it 'sends title: url lines when Meta refuses the template, and the message ends sent' do
      responses.push({ recipient_id: '1', message_id: 'mid.text' }.to_json,
                     { error: { code: 100, message: 'Invalid parameter' } }.to_json)
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(3)
      expect(deliveries[2][:message]).to eq({ text: "A: https://a\nB: https://b" })
      expect(message.reload.status).to eq('sent')
      expect(message.source_id).to eq('mid.3')
    end

    it 'leaves a non-cards message untouched' do
      message = create(:message, message_type: 'outgoing', content: 'plain', sender: agent,
                                 inbox: inbox, account: account, conversation: conversation)
      perform(message)

      expect(deliveries).to eq([{ recipient: { id: contact_inbox.source_id }, message: { text: 'plain' }, messaging_type: 'RESPONSE' }])
    end

    it 'sends no template when no item survives mapping' do
      postback_only = [{ title: 'A', actions: [{ type: 'postback', text: 'Buy', payload: 'BUY' }] }]
      perform(cards_message(inbox, conversation, items: postback_only))

      expect(deliveries.size).to eq(1)
    end
  end
end
