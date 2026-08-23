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

    it "accepts a POST signed with the channel's OWN app secret" do
      # THE ESCAPE HATCH, and the only mitigation for the one way this change
      # can take a live tenant offline: an inbox whose deliveries are signed by
      # a DIFFERENT Meta app than the installation-wide one. `#meta_app_secrets`
      # offers both and `#valid_meta_signature?` accepts any match, so giving
      # that channel its own `app_secret` restores it — no global change, no
      # other tenant affected.
      #
      # Nothing else pins this path: upstream's per-channel example runs with
      # the global secret UNSET, and the no-global context below asserts a 401.
      # A refactor that made `meta_app_secrets` return only the global when one
      # exists would 401 every different-app tenant with the suite still green.
      channel_secret = 'this-channels-own-meta-app-secret'
      manual_cloud_channel.update!(
        provider_config: manual_cloud_channel.provider_config.merge('app_secret' => channel_secret)
      )

      post_webhook(manual_cloud_channel, body, signature: signature_for(body, channel_secret))

      expect(response).to have_http_status(:success)
      expect(Webhooks::WhatsappEventsJob).to have_received(:perform_later)
    end

    it 'logs a structured warning when it rejects, naming the tenant but no secret' do
      # Upstream refuses with a bare `head :unauthorized`. Without this line,
      # seeding WHATSAPP_APP_SECRET can silently stop a tenant's inbound
      # messages with no server-side evidence of why.
      allow(Rails.logger).to receive(:warn)

      post_webhook(manual_cloud_channel, body)

      expect(response).to have_http_status(:unauthorized)
      expect(Rails.logger).to have_received(:warn).with(
        a_string_including(
          '[WHATSAPP_WEBHOOK_SIGNATURE] rejected',
          "channel_id=#{manual_cloud_channel.id}",
          "account_id=#{manual_cloud_channel.account_id}",
          'candidates=1',
          'signature_header=missing'
        )
      ).at_least(:once)
      # The whole point of a log line on a secret-checking path is that it must
      # never carry the secret it checked.
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including(global_app_secret))
    end

    it 'logs nothing when the signature is valid' do
      allow(Rails.logger).to receive(:warn)

      post_webhook(manual_cloud_channel, body, signature: signature_for(body, global_app_secret))

      expect(response).to have_http_status(:success)
      expect(Rails.logger).not_to have_received(:warn).with(a_string_including('[WHATSAPP_WEBHOOK_SIGNATURE]'))
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
