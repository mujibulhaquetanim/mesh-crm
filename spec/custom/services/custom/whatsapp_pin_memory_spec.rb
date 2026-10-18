require 'rails_helper'

# Deleting a WhatsApp inbox deregisters the number at Meta, which keeps the
# number's two-step PIN, while upstream destroys the only copy of that PIN with
# the channel row. Meta then refuses both `/register` (#133005 PIN Mismatch)
# and setting a new PIN (#133010 not registered), so re-adding the number could
# only be fixed by hand in WhatsApp Manager. These specs pin that the PIN
# outlives the channel and is used again for the same number.
RSpec.describe Custom::WhatsappPinMemory do
  let(:phone_number_id) { '123456789' }
  let(:register_url) { %r{graph\.facebook\.com/v[\d.]+/#{phone_number_id}/register\z} }
  let(:ok) { { status: 200, body: { success: true }.to_json, headers: { 'Content-Type' => 'application/json' } } }

  def build_channel(pin: nil)
    config = { 'phone_number_id' => phone_number_id, 'webhook_verify_token' => 'token',
               'business_account_id' => 'waba', 'api_key' => 'key', 'source' => 'embedded_signup' }
    config['verification_pin'] = pin if pin
    create(:channel_whatsapp, phone_number: '+1234567890', provider: 'whatsapp_cloud', provider_config: config,
                              sync_templates: false, validate_provider_config: false)
  end

  def register_through(channel)
    service = Whatsapp::WebhookSetupService.new(channel, 'waba', 'key')
    allow(service).to receive(:should_register_phone_number?).and_return(true)
    allow(service).to receive(:setup_webhook)
    service.perform
    service
  end

  before do
    stub_request(:any, /graph.facebook.com/).to_return(ok)
  end

  it 'is prepended onto the webhook setup service' do
    expect(Whatsapp::WebhookSetupService.ancestors).to include(described_class)
  end

  it 'remembers the PIN when a registration stores it' do
    channel = build_channel
    register_through(channel)

    expect(Custom::WhatsappNumberPin.recall(phone_number_id)).to eq(channel.reload.provider_config['verification_pin'].to_s)
  end

  it 'remembers the PIN when the inbox is deleted' do
    build_channel(pin: '246810').destroy!

    expect(Custom::WhatsappNumberPin.recall(phone_number_id)).to eq('246810')
  end

  it 'registers a re-added number with the PIN its deleted inbox held' do
    build_channel(pin: '246810').destroy!
    channel = build_channel
    WebMock.reset_executed_requests!

    service = register_through(channel)

    expect(a_request(:post, register_url).with(body: { messaging_product: 'whatsapp', pin: '246810' }.to_json)).to have_been_made.once
    expect(service.registration_error).to be_nil
  end

  it "prefers the channel's own PIN over a remembered one" do
    Custom::WhatsappNumberPin.remember(phone_number_id, '111111')
    register_through(build_channel(pin: '222222'))

    expect(a_request(:post, register_url).with(body: { messaging_product: 'whatsapp', pin: '222222' }.to_json)).to have_been_made.once
  end

  it 'keeps a PIN that starts with zero intact' do
    Custom::WhatsappNumberPin.remember(phone_number_id, '012345')
    register_through(build_channel)

    expect(a_request(:post, register_url).with(body: { messaging_product: 'whatsapp', pin: '012345' }.to_json)).to have_been_made.once
  end

  it 'never blocks an inbox delete when remembering fails' do
    channel = build_channel(pin: '246810')
    allow(Custom::WhatsappNumberPin).to receive(:remember).and_raise(ActiveRecord::StatementInvalid, 'boom')

    expect { channel.destroy! }.not_to raise_error
    expect(Channel::Whatsapp.exists?(channel.id)).to be(false)
  end

  it 'stores the PIN encrypted when encryption is configured' do
    skip 'Active Record encryption is not configured in this environment' unless Chatwoot.encryption_configured?

    Custom::WhatsappNumberPin.remember(phone_number_id, '246810')
    raw = Custom::WhatsappNumberPin.connection.select_value(
      "SELECT pin FROM custom_whatsapp_number_pins WHERE phone_number_id = '#{phone_number_id}'"
    )

    expect(raw).not_to include('246810')
  end
end
