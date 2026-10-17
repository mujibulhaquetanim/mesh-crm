require 'rails_helper'

# Meta keeps a number's two-step verification PIN after `/deregister`, and upstream
# stores the PIN only on the channel row. Deleting an inbox therefore loses the PIN
# while the number keeps it, and every later signup's `/register` fails with
# (#133005) PIN Mismatch: the number stays Disconnected and receives nothing.
# These specs pin that a mismatch resets the PIN (POST /{phone_number_id}, which
# Meta documents as needing no old PIN) and registers again, and that nothing
# else changes behaviour.
RSpec.describe Custom::WhatsappRegistrationPinRecovery do
  let(:phone_number_id) { '123456789' }
  let(:channel) do
    create(:channel_whatsapp,
           phone_number: '+1234567890',
           provider_config: {
             'phone_number_id' => phone_number_id,
             'webhook_verify_token' => 'test_verify_token',
             'source' => 'embedded_signup'
           },
           provider: 'whatsapp_cloud',
           sync_templates: false,
           validate_provider_config: false)
  end
  let(:service) { Whatsapp::WebhookSetupService.new(channel, 'test_waba_id', 'test_access_token') }
  let(:register_url) { %r{graph\.facebook\.com/v[\d.]+/#{phone_number_id}/register\z} }
  let(:pin_url) { %r{graph\.facebook\.com/v[\d.]+/#{phone_number_id}\z} }
  let(:pin_mismatch) do
    { error: { message: '(#133005) Two step verification PIN Mismatch', type: 'OAuthException', code: 133_005 } }.to_json
  end
  let(:ok) { { success: true }.to_json }

  before do
    stub_request(:delete, /graph.facebook.com/).to_return(status: 200, body: '{}')
    allow(service).to receive(:should_register_phone_number?).and_return(true)
    allow(service).to receive(:setup_webhook)
  end

  it 'is prepended onto the webhook setup service and the API client' do
    expect(Whatsapp::WebhookSetupService.ancestors).to include(described_class)
    expect(Whatsapp::FacebookApiClient.ancestors).to include(Custom::WhatsappTwoStepPin)
  end

  context 'when /register fails with a PIN mismatch' do
    before do
      stub_request(:post, register_url).to_return(
        { status: 400, body: pin_mismatch, headers: { 'Content-Type' => 'application/json' } },
        { status: 200, body: ok, headers: { 'Content-Type' => 'application/json' } }
      )
      stub_request(:post, pin_url).to_return(status: 200, body: ok, headers: { 'Content-Type' => 'application/json' })
    end

    it 'sets a new PIN, registers with it, stores it, and clears the error' do
      service.perform

      stored_pin = channel.reload.provider_config['verification_pin'].to_s
      expect(stored_pin).to match(/\A\d{6}\z/)
      expect(a_request(:post, pin_url).with(body: { pin: stored_pin }.to_json)).to have_been_made.once
      expect(a_request(:post, register_url).with(body: { messaging_product: 'whatsapp', pin: stored_pin }.to_json))
        .to have_been_made.once
      expect(a_request(:post, register_url)).to have_been_made.twice
      expect(service.registration_error).to be_nil
    end

    it 'still sets up the webhook afterwards' do
      service.perform

      expect(service).to have_received(:setup_webhook)
    end
  end

  context 'when the PIN reset itself fails' do
    before do
      stub_request(:post, register_url).to_return(status: 400, body: pin_mismatch, headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, pin_url).to_return(status: 403, body: { error: { message: 'denied', code: 200 } }.to_json)
    end

    it 'keeps a registration error, stores no PIN, and does not raise' do
      expect { service.perform }.not_to raise_error

      expect(service.registration_error).to be_present
      expect(channel.reload.provider_config['verification_pin']).to be_nil
      expect(a_request(:post, register_url)).to have_been_made.once
    end
  end

  context 'when /register fails for any other reason' do
    before do
      stub_request(:post, register_url).to_return(
        status: 400, body: { error: { message: '(#131000) Something went wrong', code: 131_000 } }.to_json
      )
      stub_request(:post, pin_url)
    end

    it 'leaves the PIN alone and keeps upstream behaviour' do
      service.perform

      expect(a_request(:post, pin_url)).not_to have_been_made
      expect(service.registration_error.message).to include('131000')
    end
  end

  context 'when /register succeeds first time' do
    before do
      stub_request(:post, register_url).to_return(status: 200, body: ok, headers: { 'Content-Type' => 'application/json' })
      stub_request(:post, pin_url)
    end

    it 'never resets the PIN' do
      service.perform

      expect(a_request(:post, pin_url)).not_to have_been_made
      expect(service.registration_error).to be_nil
      expect(channel.reload.provider_config['verification_pin']).to be_present
    end
  end
end
