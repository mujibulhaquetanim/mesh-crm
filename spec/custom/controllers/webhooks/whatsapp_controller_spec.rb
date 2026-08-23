require 'rails_helper'

# Fork override: `X-Hub-Signature-256` is REQUIRED on every whatsapp_cloud
# webhook POST once the installation has an app secret to verify with.
#
# Upstream only requires it when the CHANNEL can prove a secret (one in
# `provider_config`, or `source == 'embedded_signup'`), which left the
# manual-source cloud inboxes this platform provisions accepting unsigned
# POSTs — anyone who knows a tenant's phone number could inject inbound
# customer messages that the AI agent then answers. The installation-wide
# `WHATSAPP_APP_SECRET` was already a verification CANDIDATE upstream
# (`Webhooks::WhatsappController#meta_app_secrets`); it just never made
# verification mandatory.
#
# See custom/app/controllers/custom/webhooks/whatsapp_controller.rb.
RSpec.describe 'Webhooks::WhatsappController (fork signature enforcement)', type: :request do
  let(:global_app_secret) { 'installation-wide-meta-app-secret' }
  let(:body) { { content: 'hello' }.to_json }

  # The inbox shape this fork actually provisions: whatsapp_cloud, manual
  # source, and NO app secret in provider_config (that column is serialized to
  # every tenant admin — see Custom::Channel::Whatsapp).
  #
  # The factory stamps `source => 'embedded_signup'` at create time to keep the
  # real webhook-registration call from firing; stripping it afterwards with
  # `update!` leaves a manual-source channel without re-running the create-only
  # `after_commit :setup_webhooks`.
  let(:manual_cloud_channel) do
    channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    channel.update!(provider_config: channel.provider_config.except('source'))
    channel
  end

  def signature_for(payload, secret)
    "sha256=#{OpenSSL::HMAC.hexdigest('SHA256', secret, payload)}"
  end

  def post_webhook(channel, payload, signature: nil)
    headers = { 'CONTENT_TYPE' => 'application/json' }
    headers['X-Hub-Signature-256'] = signature if signature

    post "/webhooks/whatsapp/#{channel.phone_number}", params: payload, headers: headers
  end

  # `GlobalConfigService.load` persists an InstallationConfig row the first time
  # it reads an ENV-supplied value, and GlobalConfig caches in Redis — so a
  # previous example can otherwise leak a configured secret into one that is
  # meant to have none.
  before do
    InstallationConfig.where(name: 'WHATSAPP_APP_SECRET').delete_all
    GlobalConfig.clear_cache
    allow(Webhooks::WhatsappEventsJob).to receive(:perform_later)
  end

  context 'when the installation has a global WhatsApp app secret' do
    around do |example|
      with_modified_env(WHATSAPP_APP_SECRET: global_app_secret) { example.run }
    end

    it 'rejects an unsigned POST to a manual-source cloud inbox' do
      post_webhook(manual_cloud_channel, body)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'rejects a POST signed with the wrong secret' do
      post_webhook(manual_cloud_channel, body, signature: signature_for(body, 'not-the-app-secret'))

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end

    it 'accepts a POST signed with the global app secret' do
      post_webhook(manual_cloud_channel, body, signature: signature_for(body, global_app_secret))

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'still accepts an unsigned POST for a 360dialog inbox' do
      # provider 'default' is not a Meta webhook at all — it never carries
      # X-Hub-Signature-256, so requiring one would take the inbox offline.
      dialog_channel = create(:channel_whatsapp, provider: 'default', sync_templates: false, validate_provider_config: false)

      post_webhook(dialog_channel, body)

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'leaves the GET verification handshake signature-free' do
      # Meta signs deliveries, not the subscription handshake; requiring a
      # signature here would make the inbox impossible to register.
      get "/webhooks/whatsapp/#{manual_cloud_channel.phone_number}",
          params: { 'hub.challenge' => '123456', 'hub.mode' => 'subscribe',
                    'hub.verify_token' => manual_cloud_channel.provider_config['webhook_verify_token'] }

      expect(response).to have_http_status(:success)
      expect(response.body).to include('123456')
    end
  end

  context 'when the installation has no WhatsApp app secret configured' do
    # `nil` makes ClimateControl UNSET the variable, so the pin holds even on a
    # box whose real environment exports one.
    around do |example|
      with_modified_env(WHATSAPP_APP_SECRET: nil) { example.run }
    end

    # Pins the no-regression half of the change: a stock deployment that never
    # set WHATSAPP_APP_SECRET behaves exactly as upstream does.
    it 'accepts an unsigned POST to a manual-source cloud inbox' do
      post_webhook(manual_cloud_channel, body)

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'still requires a signature when the channel carries its own app secret' do
      manual_cloud_channel.update!(provider_config: manual_cloud_channel.provider_config.merge('app_secret' => 'per-channel-secret'))

      post_webhook(manual_cloud_channel, body)

      expect(response).to have_http_status(:unauthorized)
      expect(Webhooks::WhatsappEventsJob).not_to have_received(:perform_later)
    end
  end
end
