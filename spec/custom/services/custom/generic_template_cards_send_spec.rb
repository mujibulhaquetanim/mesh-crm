require 'rails_helper'

# A `cards` message on a Messenger or Instagram inbox: upstream sends its text
# (and attachments) as before, then the overlay sends the cards as one generic
# template, LAST, so the customer reads the answer first. The message keeps the
# TEXT's mid as `source_id`: on Instagram the inbox drops an echo only when its
# mid matches, and the text echo is the one that would otherwise come back as
# a duplicate of the reply.
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

  it 'is prepended onto both send services' do
    expect(Facebook::SendOnFacebookService.ancestors).to include(described_class)
    expect(Instagram::BaseSendService.ancestors).to include(described_class)
  end

  # Instagram Login (graph.instagram.com) and Instagram through a Page
  # (graph.facebook.com) share Instagram::BaseSendService and its order:
  # attachments, then the text, then (the overlay) the template.
  shared_examples 'an Instagram cards send' do
    # The conversation (and so the channel) first: creating an Instagram
    # channel posts to Meta itself, and that call must not count as a send.
    before do
      create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation)
      allow(HTTParty).to receive(:post) do |_url, options|
        bodies << options[:body]
        next_response = responses.shift
        raise next_response if next_response.is_a?(Exception) || next_response.is_a?(Class)

        next_response || ok_response("ig.mid.#{bodies.size}")
      end
    end

    let(:bodies) { [] }
    let(:responses) { [] }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
    let(:conversation) { create(:conversation, contact: contact, inbox: inbox, contact_inbox: contact_inbox) }

    def ok_response(mid)
      instance_double(HTTParty::Response, success?: true, body: { message_id: mid }.to_json,
                                          parsed_response: { 'message_id' => mid })
    end

    def refused_response
      body = { 'error' => { 'code' => 100, 'message' => 'Invalid parameter' } }
      instance_double(HTTParty::Response, success?: false, body: body.to_json, parsed_response: body)
    end

    it 'sends attachments, then the text, then the template, and keeps the text mid' do
      message = cards_message(inbox, conversation)
      photo = message.attachments.new(account_id: account.id, file_type: :image)
      photo.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
      message.save!
      service_class.new(message: message).perform

      expect(bodies.size).to eq(3)
      expect(bodies[0].dig(:message, :attachment, :type)).to eq('image')
      expect(bodies[1][:message]).to eq({ text: 'Here you go' })
      template = JSON.parse(bodies[2][:message])
      expect(template.dig('attachment', 'payload', 'template_type')).to eq('generic')
      expect(template.dig('attachment', 'payload', 'elements').map { |e| e['title'] }).to eq(%w[A B])
      expect(message.reload.source_id).to eq('ig.mid.2')
    end

    # HTTParty form-encodes a Hash body, and an array of hashes becomes
    # `elements[][title]=…&elements[][buttons][][type]=…`, which Graph parses
    # into a different element per field. The template goes as JSON text.
    it 'sends the template in a body that form-encodes without an array of hashes' do
      service_class.new(message: cards_message(inbox, conversation)).perform

      expect(bodies.size).to eq(2)
      expect(HTTParty::HashConversions.to_params(bodies.last)).not_to include('%5B%5D')
    end

    it 'sends title: url lines when the template is refused, and the message ends sent' do
      responses.push(ok_response('ig.mid.text'), refused_response)
      message = cards_message(inbox, conversation)
      service_class.new(message: message).perform

      expect(bodies.size).to eq(3)
      expect(bodies[2][:message]).to eq({ text: "A: https://a\nB: https://b" })
      expect(message.reload.status).to eq('sent')
      expect(message.source_id).to eq('ig.mid.text')
    end

    it 'sends no cards when the text itself was refused, and keeps its error' do
      responses.push(refused_response)
      message = cards_message(inbox, conversation)
      service_class.new(message: message).perform

      expect(bodies.size).to eq(1)
      expect(message.reload.status).to eq('failed')
      expect(message.external_error).to include('Invalid parameter')
    end

    it 'sends no fallback after a read timeout (Meta may have shown the cards)' do
      responses.push(ok_response('ig.mid.text'), Net::ReadTimeout)
      message = cards_message(inbox, conversation)
      service_class.new(message: message).perform

      expect(bodies.size).to eq(2)
      expect(message.reload.status).to eq('sent')
    end

    it 'leaves a non-cards message untouched, including what perform returns' do
      message = create(:message, message_type: 'outgoing', content: 'plain', sender: agent,
                                 inbox: inbox, account: account, conversation: conversation)
      result = service_class.new(message: message).perform

      expect(bodies.size).to eq(1)
      expect(result).to eq({ 'message_id' => 'ig.mid.1' })
    end
  end

  describe 'on Instagram (Instagram Login)' do
    let(:inbox) do
      create(:inbox, channel: create(:channel_instagram, account: account, instagram_id: 'ig-1'),
                     account: account, greeting_enabled: false)
    end
    let(:service_class) { Instagram::SendOnInstagramService }

    it_behaves_like 'an Instagram cards send'
  end

  describe 'on Instagram through a Page' do
    let(:inbox) do
      create(:inbox, channel: create(:channel_instagram_fb_page, account: account, instagram_id: 'ig-2'),
                     account: account, greeting_enabled: false)
    end
    let(:service_class) { Instagram::Messenger::SendOnInstagramService }

    it_behaves_like 'an Instagram cards send'
  end

  describe 'on Messenger' do
    # Before the `let!`s: creating the channel subscribes the Page. The real
    # Bot.deliver RAISES a FacebookError for a refused send (the gem's
    # ErrorParser), so the stub does the same for an Exception in `responses`.
    before do
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
      allow(bot).to receive(:deliver) do |params, _options|
        deliveries << params
        next_response = responses.shift
        raise next_response if next_response.is_a?(Exception) || next_response.is_a?(Class)

        next_response || { recipient_id: '1', message_id: "mid.#{deliveries.size}" }.to_json
      end
      create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation)
    end

    let(:bot) { class_double(Facebook::Messenger::Bot).as_stubbed_const }
    let(:deliveries) { [] }
    let(:responses) { [] }
    let(:refused) { Facebook::Messenger::FacebookError.new('message' => 'Invalid parameter', 'code' => 100) }
    let!(:channel) { create(:channel_facebook_page, account: account) }
    let!(:inbox) { create(:inbox, channel: channel, account: account) }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
    let(:conversation) { create(:conversation, contact: contact, inbox: inbox, contact_inbox: contact_inbox) }

    def perform(message)
      Facebook::SendOnFacebookService.new(message: message).perform
    end

    it 'sends the text, then one generic template, and keeps the text mid' do
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(2)
      expect(deliveries[0][:message]).to eq({ text: 'Here you go' })
      payload = deliveries[1].dig(:message, :attachment)
      expect(payload[:type]).to eq('template')
      expect(payload[:payload][:template_type]).to eq('generic')
      expect(payload[:payload][:elements].map { |e| e[:title] }).to eq(%w[A B])
      expect(deliveries[1][:recipient]).to eq({ id: contact_inbox.source_id })
      expect(message.reload.source_id).to eq('mid.1')
    end

    it 'stores the template mid for a cards message with no text' do
      message = cards_message(inbox, conversation, content: nil)
      perform(message)

      expect(deliveries.size).to eq(1)
      expect(message.reload.source_id).to eq('mid.1')
    end

    it 'uses the same messaging_type as the text' do
      perform(cards_message(inbox, conversation))

      expect(deliveries.map { |d| d[:messaging_type] }).to eq(%w[RESPONSE RESPONSE])
    end

    it "sends title: url lines when Meta refuses the template, and logs Meta's reason" do
      allow(Rails.logger).to receive(:warn)
      responses.push(nil, refused)
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(3)
      expect(deliveries[2][:message]).to eq({ text: "A: https://a\nB: https://b" })
      expect(message.reload.status).to eq('sent')
      expect(Rails.logger).to have_received(:warn).with(a_string_including('Invalid parameter'))
    end

    it 'sends no cards when the text itself was refused, and keeps its error' do
      responses.push(refused)
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(1)
      expect(message.reload.status).to eq('failed')
    end

    # The text reached the customer; a `failed` status would invite a Retry,
    # which re-sends the whole message.
    it 'keeps the message sent when the cards and the fallback both fail after the text went' do
      responses.push(nil, refused, refused)
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(3)
      expect(message.reload.status).to eq('sent')
    end

    it 'marks a cards-only message failed when the cards and the fallback both fail' do
      responses.push(refused, refused)
      message = cards_message(inbox, conversation, content: nil)
      perform(message)

      expect(message.reload.status).to eq('failed')
      expect(message.external_error).to be_present
    end

    it 'does not raise when sending the fallback raises' do
      responses.push(refused, Errno::ECONNRESET)
      message = cards_message(inbox, conversation, content: nil)

      expect { perform(message) }.not_to raise_error
      expect(message.reload.status).to eq('failed')
    end

    it 'sends no fallback after a read timeout (Meta may have shown the cards)' do
      responses.push(nil, Net::ReadTimeout)
      message = cards_message(inbox, conversation)
      perform(message)

      expect(deliveries.size).to eq(2)
      expect(message.reload.status).to eq('sent')
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
