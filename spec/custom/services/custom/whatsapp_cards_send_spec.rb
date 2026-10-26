require 'rails_helper'

# A `cards` message on a WhatsApp Cloud inbox: upstream sends its text, then
# the overlay sends one interactive "call to action URL" message per product
# (photo header, name and description, a button to the product page). The
# text's wamid stays the message's source_id.
RSpec.describe Custom::WhatsappCardsSend do
  subject(:service) { Whatsapp::Providers::WhatsappCloudService.new(whatsapp_channel: whatsapp_channel) }

  let(:whatsapp_channel) do
    create(:channel_whatsapp, provider: 'whatsapp_cloud', validate_provider_config: false, sync_templates: false)
  end
  let(:conversation) { create(:conversation, inbox: whatsapp_channel.inbox) }
  let(:text_url) { 'https://graph.facebook.com/v13.0/123456789/messages' }
  let(:cards_url) { 'https://graph.facebook.com/v22.0/123456789/messages' }
  let(:upload_url) { 'https://graph.facebook.com/v22.0/123456789/media' }
  let(:photo_url) { 'https://api.shop.test/public/img/tok/v%3A1' }
  let(:json) { { 'Content-Type' => 'application/json' } }
  let(:items) do
    [
      { title: 'Spool Heel', description: '৳999 · Rose gold block heel', media_url: photo_url,
        actions: [{ type: 'link', text: 'View details', uri: 'https://shop.test/spool' }] },
      { title: 'Hourglass Heel', actions: [{ type: 'link', text: 'View details', uri: 'https://shop.test/hourglass' }] }
    ]
  end
  let(:card_bodies) { [] }

  def cards_message(content: 'Here are some heels you might love!', items: self.items)
    create(:message, conversation: conversation, message_type: :outgoing, content: content, content_type: 'cards',
                     content_attributes: { items: items }, inbox: whatsapp_channel.inbox)
  end

  def ok(id)
    { status: 200, body: { messages: [{ id: id }] }.to_json, headers: json }
  end

  def refused
    { status: 400, body: { error: { message: 'Invalid parameter', code: 100 } }.to_json, headers: json }
  end

  def stub_cards(*responses)
    stub_request(:post, cards_url).to_return(*responses).then.to_return(ok('wamid.extra'))
    WebMock.after_request do |request, _response|
      # WebMock's URI carries the port (graph.facebook.com:443), so compare the path.
      card_bodies << JSON.parse(request.body) if request.uri.path == '/v22.0/123456789/messages'
    end
  end

  around do |example|
    ClimateControl.modify(CARD_MEDIA_ALLOWED_HOSTS: 'api.shop.test', CARD_MEDIA_REDIRECT_HOSTS: 'r2.shop.test') do
      example.run
    end
  end

  before do
    # Test hosts resolve to a public address unless a test says otherwise.
    allow(Resolv).to receive(:getaddresses).and_return(['93.184.216.34'])
    stub_request(:get, /message_templates/)
    stub_request(:post, text_url).to_return(ok('wamid.text'))
    stub_request(:get, photo_url).to_return(status: 302, headers: { 'Location' => 'https://r2.shop.test/photo.jpg' })
    stub_request(:get, 'https://r2.shop.test/photo.jpg')
      .to_return(status: 200, body: 'JPEGBYTES', headers: { 'Content-Type' => 'image/jpeg' })
    stub_request(:post, upload_url).to_return(status: 200, body: { id: 'media-1' }.to_json, headers: json)
  end

  after { WebMock::CallbackRegistry.reset }

  it 'is prepended onto the WhatsApp Cloud provider only' do
    expect(Whatsapp::Providers::WhatsappCloudService.ancestors).to include(described_class)
    expect(Whatsapp::Providers::Whatsapp360DialogService.ancestors).not_to include(described_class)
  end

  it 'sends the text first, then one message per product, and keeps the text wamid' do
    stub_cards(ok('wamid.c1'), ok('wamid.c2'))

    expect(service.send_message('+123456789', cards_message)).to eq('wamid.text')
    expect(a_request(:post, text_url)).to have_been_made.once
    expect(card_bodies.size).to eq(2)
  end

  it 'gives each card its photo, name, description and button' do
    stub_cards(ok('wamid.c1'), ok('wamid.c2'))
    service.send_message('+123456789', cards_message)

    first = card_bodies.first['interactive']
    expect(card_bodies.first).to include('type' => 'interactive', 'to' => '+123456789')
    expect(first['type']).to eq('cta_url')
    expect(first['header']).to eq('type' => 'image', 'image' => { 'id' => 'media-1' })
    expect(first['body']['text']).to eq("*Spool Heel*\n৳999 · Rose gold block heel")
    expect(first['action']).to eq('name' => 'cta_url',
                                  'parameters' => { 'display_text' => 'View details', 'url' => 'https://shop.test/spool' })
    expect(card_bodies.second['interactive']).not_to have_key('header')
    expect(card_bodies.second['interactive']['body']['text']).to eq('*Hourglass Heel*')
  end

  it 'never fetches a photo from a host that is not allowed, and sends the card without it' do
    stub_cards(ok('wamid.c1'), ok('wamid.c2'))
    other = 'https://evil.test/x.jpg'
    stub_request(:get, other)

    service.send_message('+123456789', cards_message(items: [items.first.merge(media_url: other)]))

    expect(a_request(:get, other)).not_to have_been_made
    expect(card_bodies.first['interactive']).not_to have_key('header')
  end

  it 'refuses a redirect off https, and sends the card without the photo' do
    stub_cards(ok('wamid.c1'))
    stub_request(:get, photo_url).to_return(status: 302, headers: { 'Location' => 'http://169.254.169.254/latest' })

    service.send_message('+123456789', cards_message(items: [items.first]))

    expect(a_request(:get, 'http://169.254.169.254/latest')).not_to have_been_made
    expect(a_request(:post, upload_url)).not_to have_been_made
    expect(card_bodies.first['interactive']).not_to have_key('header')
  end

  it 'refuses a redirect to an https host on neither list' do
    stub_cards(ok('wamid.c1'))
    stub_request(:get, photo_url).to_return(status: 302, headers: { 'Location' => 'https://internal.corp.test/secret' })

    service.send_message('+123456789', cards_message(items: [items.first]))

    expect(a_request(:get, 'https://internal.corp.test/secret')).not_to have_been_made
    expect(card_bodies.first['interactive']).not_to have_key('header')
  end

  it 'refuses a listed host that resolves to a private address' do
    stub_cards(ok('wamid.c1'))
    allow(Resolv).to receive(:getaddresses).with('api.shop.test').and_return(['10.0.0.5'])

    service.send_message('+123456789', cards_message(items: [items.first]))

    expect(a_request(:get, photo_url)).not_to have_been_made
    expect(card_bodies.first['interactive']).not_to have_key('header')
  end

  it 'uploads only a JPEG or PNG' do
    stub_cards(ok('wamid.c1'))
    stub_request(:get, 'https://r2.shop.test/photo.jpg')
      .to_return(status: 200, body: '<html>', headers: { 'Content-Type' => 'text/html' })

    service.send_message('+123456789', cards_message(items: [items.first]))

    expect(a_request(:post, upload_url)).not_to have_been_made
    expect(card_bodies.first['interactive']).not_to have_key('header')
  end

  it 'sends no cards when the text itself failed' do
    stub_cards(ok('wamid.c1'))
    stub_request(:post, text_url).to_return(refused)
    message = cards_message

    expect(service.send_message('+123456789', message)).to be_nil
    expect(card_bodies).to be_empty
    expect(message.reload.status).to eq('failed')
  end

  it 'sends the refused cards as "title: url" lines and keeps the message sent' do
    stub_cards(ok('wamid.c1'), refused)
    stub_request(:post, cards_url).with(body: /"type":"text"/).to_return(ok('wamid.fallback'))
    message = cards_message

    expect(service.send_message('+123456789', message)).to eq('wamid.text')
    expect(a_request(:post, cards_url).with(body: %r{Hourglass Heel: https://shop.test/hourglass})).to have_been_made
    expect(a_request(:post, cards_url).with(body: /Spool Heel: /)).not_to have_been_made
    expect(message.reload.status).not_to eq('failed')
  end

  it 'marks a cards-only message failed when nothing reached the customer' do
    stub_request(:post, cards_url).to_return(refused)
    message = cards_message(content: nil)

    expect(service.send_message('+123456789', message)).to be_nil
    expect(message.reload.status).to eq('failed')
    expect(message.external_error).to eq('The product cards could not be delivered')
  end

  it 'keeps the first card wamid for a cards-only message' do
    stub_cards(ok('wamid.c1'), ok('wamid.c2'))

    expect(service.send_message('+123456789', cards_message(content: nil))).to eq('wamid.c1')
    expect(a_request(:post, text_url)).not_to have_been_made
  end

  it 'leaves every other message to upstream' do
    message = create(:message, conversation: conversation, message_type: :outgoing, content: 'hi',
                               inbox: whatsapp_channel.inbox)

    expect(service.send_message('+123456789', message)).to eq('wamid.text')
    expect(a_request(:post, cards_url)).not_to have_been_made
  end

  it 'clips a long body and button to what WhatsApp accepts, without bold markers in the name' do
    long = items.first.merge(title: '*Spool*', description: 'x' * 2000,
                             actions: [{ type: 'link', text: 'See every detail of it', uri: 'https://shop.test/spool' }])
    stub_cards(ok('wamid.c1'))

    service.send_message('+123456789', cards_message(items: [long]))

    interactive = card_bodies.first['interactive']
    expect(interactive['body']['text']).to start_with("*Spool*\nxxx")
    expect(interactive['body']['text'].length).to be <= 1024
    expect(interactive['action']['parameters']['display_text'].length).to be <= 20
  end
end
