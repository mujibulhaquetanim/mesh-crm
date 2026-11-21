require 'rails_helper'

# A customer's "Reply" on one part of a multi-part message (its text, a photo,
# or the product cards) must still link to that message.
#
# The bug (agentic-str ts/809, measured on production 2026-11-21): a Messenger
# reply to the product-card template quoted the template's mid; the message
# had stored only its text's mid, so upstream's InReplyToMessageBuilder found
# nothing and cleared BOTH reply fields. The platform API received a plain
# message and the AI answered about the last product in the chat.
RSpec.describe Custom::InReplyToPartLookup do
  # Before the `let!`s: creating the channel subscribes the Page to Meta.
  before do
    allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
    allow(bot).to receive(:deliver) do |params, _options|
      deliveries << params
      { recipient_id: '1', message_id: "mid.#{deliveries.size}" }.to_json
    end
    create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation)
  end

  let!(:account) { create(:account) }
  let(:agent) { create(:user, account: account) }
  let(:bot) { class_double(Facebook::Messenger::Bot).as_stubbed_const }
  let(:deliveries) { [] }
  let!(:channel) { create(:channel_facebook_page, account: account) }
  let!(:inbox) { create(:inbox, channel: channel, account: account) }
  let(:contact) { create(:contact, account: account) }
  let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: inbox) }
  let(:conversation) { create(:conversation, contact: contact, inbox: inbox, contact_inbox: contact_inbox) }
  let(:items) do
    [{ title: 'Diamond Handbag', actions: [{ type: 'link', text: 'View details', uri: 'https://shop.example/d' }] }]
  end

  def sent_cards_message(content: 'Here is the red one')
    message = create(:message, message_type: 'outgoing', content: content, content_type: 'cards',
                               content_attributes: { items: items }, sender: agent,
                               inbox: inbox, account: account, conversation: conversation)
    Facebook::SendOnFacebookService.new(message: message).perform
    message.reload
  end

  def sent_photo_message
    message = create(:message, message_type: 'outgoing', content: 'Two colours', sender: agent,
                               inbox: inbox, account: account, conversation: conversation)
    2.times do
      photo = message.attachments.new(account_id: account.id, file_type: :image)
      photo.file.attach(io: Rails.root.join('spec/assets/avatar.png').open, filename: 'avatar.png', content_type: 'image/png')
    end
    message.save!
    Facebook::SendOnFacebookService.new(message: message).perform
    message.reload
  end

  def customer_reply(quoted_mid, in_conversation: conversation)
    create(:message, message_type: :incoming, inbox: in_conversation.inbox, account: account,
                     conversation: in_conversation, content: 'how much is this?',
                     content_attributes: { in_reply_to_external_id: quoted_mid }).reload
  end

  it 'is prepended onto the reply builder' do
    expect(Messages::InReplyToMessageBuilder.ancestors).to include(described_class)
  end

  it 'records the text mid and the cards mid on the message' do
    message = sent_cards_message

    expect(message.source_id).to eq('mid.1')
    expect(message.content_attributes['meta_part_ids']).to eq(%w[mid.1 mid.2])
  end

  it 'links a reply to the product cards to the message (the reported bug)' do
    message = sent_cards_message
    reply = customer_reply('mid.2')

    expect(reply.content_attributes['in_reply_to']).to eq(message.id)
    expect(reply.content_attributes['in_reply_to_external_id']).to eq('mid.1')
  end

  it 'still links a reply to the text through upstream lookup' do
    message = sent_cards_message
    reply = customer_reply('mid.1')

    expect(reply.content_attributes['in_reply_to']).to eq(message.id)
  end

  it 'links a reply to the first of two photos, whose mid the message no longer stores' do
    message = sent_photo_message

    expect(message.source_id).to eq('mid.3') # upstream keeps the last part's
    expect(message.content_attributes['meta_part_ids']).to eq(%w[mid.1 mid.2 mid.3])
    expect(customer_reply('mid.2').content_attributes['in_reply_to']).to eq(message.id)
    expect(customer_reply('mid.1').content_attributes['in_reply_to']).to eq(message.id)
  end

  it 'keeps the quoted id when no message has it, so the reply still reads as a reply' do
    reply = customer_reply('mid.unknown')

    expect(reply.content_attributes['in_reply_to']).to be_nil
    expect(reply.content_attributes['in_reply_to_external_id']).to eq('mid.unknown')
  end

  # The WhatsApp send passes this field to Meta as the reply context; an id
  # Meta does not know would fail the send, so outgoing keeps upstream's clear.
  it "keeps upstream's clear on an outgoing message whose quoted id is unknown" do
    outgoing = create(:message, message_type: :outgoing, inbox: inbox, account: account, conversation: conversation,
                                sender: agent, content: 'x', content_attributes: { in_reply_to_external_id: 'mid.unknown' })

    expect(outgoing.reload.content_attributes['in_reply_to_external_id']).to be_nil
  end

  it 'leaves a plain message without reply fields' do
    plain = create(:message, message_type: :incoming, inbox: inbox, account: account,
                             conversation: conversation, content: 'hi').reload

    expect(plain.content_attributes).not_to have_key('in_reply_to')
    expect(plain.content_attributes).not_to have_key('in_reply_to_external_id')
  end

  it 'never links to a part of a message in another conversation' do
    sent_cards_message
    other_contact = create(:contact, account: account)
    other = create(:conversation, contact: other_contact, inbox: inbox,
                                  contact_inbox: create(:contact_inbox, contact: other_contact, inbox: inbox))
    reply = customer_reply('mid.2', in_conversation: other)

    expect(reply.content_attributes['in_reply_to']).to be_nil
    expect(reply.content_attributes['in_reply_to_external_id']).to eq('mid.2')
  end

  it 'never matches a customer message by recorded parts (only outgoing messages record them)' do
    incoming = create(:message, message_type: :incoming, inbox: inbox, account: account, conversation: conversation,
                                content: 'mine', source_id: 'mid.customer')

    expect(incoming.reload.content_attributes).not_to have_key('meta_part_ids')
  end

  it 'records nothing on a channel without Meta parts' do
    api_inbox = create(:inbox, channel: create(:channel_api, account: account), account: account)
    api_conversation = create(:conversation, inbox: api_inbox, account: account)
    message = create(:message, message_type: :outgoing, inbox: api_inbox, account: account,
                               conversation: api_conversation, content: 'x')
    message.update!(source_id: 'external-1')

    expect(message.reload.content_attributes).not_to have_key('meta_part_ids')
  end

  it 'caps the list' do
    message = sent_cards_message
    Custom::MetaPartIds.add(message, (1..40).map { |n| "extra.#{n}" })

    expect(message.content_attributes['meta_part_ids'].size).to eq(Custom::MetaPartIds::MAX)
    expect(message.content_attributes['meta_part_ids'].last).to eq('extra.40')
  end
end
