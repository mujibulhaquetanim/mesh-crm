require 'rails_helper'

# Fork validation: a manual-source whatsapp_cloud channel must be set up with a
# token from the Meta app this installation verifies webhooks with, unless the
# channel carries its own app secret.
#
# Meta signs every delivery with the secret of the app the token belongs to
# (manual setup subscribes THAT app to the WABA). Once `WHATSAPP_APP_SECRET` is
# seeded, `Custom::Webhooks::WhatsappController` requires a signature it can
# verify, and the installation secret is the only candidate on a channel with
# no secret of its own. A token from any other app therefore produced an inbox
# that 401'd every inbound message while the UI showed nothing. This turns that
# into a refusal at setup time, with a message the setup form displays.
#
# See custom/app/models/custom/channel/whatsapp.rb.
RSpec.describe Channel::Whatsapp do
  let(:installation_app_id) { '111111111111111' }
  let(:installation_secret) { 'installation-wide-meta-app-secret' }
  let(:debug_token_url) { %r{\Ahttps://graph\.facebook\.com/v[\d.]+/debug_token} }

  def stub_token_app(app_id:, is_valid: true)
    stub_request(:get, debug_token_url).to_return(
      status: 200,
      body: { data: { app_id: app_id, is_valid: is_valid } }.to_json,
      headers: { 'Content-Type' => 'application/json' }
    )
  end

  # A manual-source cloud channel that has not been saved: `valid?` runs the
  # whole validation chain without the create-time template sync and webhook
  # registration. Upstream's own remote credential check is stubbed to pass so
  # each example isolates the fork's check.
  def manual_channel(provider_config = {})
    build(
      :channel_whatsapp,
      account: create(:account),
      provider: 'whatsapp_cloud',
      provider_config: { 'api_key' => 'manual-token', 'phone_number_id' => '123',
                         'business_account_id' => '456' }.merge(provider_config)
    ).tap { |channel| channel.provider_config.delete('source') unless provider_config.key?('source') }
  end

  before do
    InstallationConfig.where(name: %w[WHATSAPP_APP_SECRET WHATSAPP_APP_ID]).delete_all
    GlobalConfig.clear_cache
    allow_any_instance_of(Whatsapp::Providers::WhatsappCloudService) # rubocop:disable RSpec/AnyInstance
      .to receive(:validate_provider_config?).and_return(true)
  end

  context 'when the installation verifies webhooks with its own app secret' do
    around do |example|
      with_modified_env(WHATSAPP_APP_SECRET: installation_secret, WHATSAPP_APP_ID: installation_app_id) { example.run }
    end

    it 'accepts a token issued by the installation app' do
      stub_token_app(app_id: installation_app_id)

      expect(manual_channel).to be_valid
    end

    it 'refuses a token issued by a different Meta app, with a message the setup form shows' do
      stub_token_app(app_id: '999999999999999')
      channel = manual_channel

      expect(channel).not_to be_valid
      expect(channel.errors.full_messages.join).to include('different Meta app')
    end

    it 'logs the refusal without the token or any secret' do
      stub_token_app(app_id: '999999999999999')
      allow(Rails.logger).to receive(:warn)

      manual_channel.valid?

      expect(Rails.logger).to have_received(:warn).with(
        a_string_including('[WHATSAPP_TOKEN_APP] refused', 'token_app_id="999999999999999"')
          .and(satisfy { |line| line.exclude?('manual-token') && line.exclude?(installation_secret) })
      )
    end

    it 'refuses an expired or revoked token from the installation app' do
      stub_token_app(app_id: installation_app_id, is_valid: false)

      expect(manual_channel).not_to be_valid
    end

    it 'fails closed when Meta cannot confirm which app the token belongs to' do
      # What debug_token answers when the token is not from the app whose app
      # token asks: "The tokens must be from the same app."
      stub_request(:get, debug_token_url).to_return(status: 400, body: { error: { code: 100 } }.to_json)

      expect(manual_channel).not_to be_valid
    end

    it 'fails closed without a Graph call when the installation app id is missing' do
      with_modified_env(WHATSAPP_APP_ID: nil) do
        InstallationConfig.where(name: 'WHATSAPP_APP_ID').delete_all
        GlobalConfig.clear_cache

        expect(manual_channel).not_to be_valid
      end
      expect(a_request(:get, debug_token_url)).not_to have_been_made
    end

    it 'skips the check when the channel carries its own app secret' do
      expect(manual_channel('app_secret' => 'vendor-own-app-secret')).to be_valid
      expect(a_request(:get, debug_token_url)).not_to have_been_made
    end

    it 'skips the check for embedded signup, whose token the installation app issued itself' do
      expect(manual_channel('source' => 'embedded_signup')).to be_valid
      expect(a_request(:get, debug_token_url)).not_to have_been_made
    end

    context 'with a saved channel' do
      # A fresh instance: the factory switches remote credential checks off with
      # a singleton method on the object it returns, which would hide this one.
      let(:channel) do
        saved = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
        saved.update_columns(provider_config: saved.provider_config.except('source')) # rubocop:disable Rails/SkipsModelValidations
        described_class.find(saved.id)
      end

      it 'does not re-check when the token is unchanged' do
        channel.provider_config = channel.provider_config.merge('calling_enabled' => false)

        expect(channel).to be_valid
        expect(a_request(:get, debug_token_url)).not_to have_been_made
      end

      it 'checks a rotated token' do
        stub_token_app(app_id: '999999999999999')
        channel.provider_config = channel.provider_config.merge('api_key' => 'rotated-foreign-token')

        expect(channel).not_to be_valid
      end

      it 'treats a stored app secret as present on the redacted write-back' do
        channel.update_columns(provider_config: channel.provider_config.merge('app_secret' => 'stored')) # rubocop:disable Rails/SkipsModelValidations
        # What ConfigurationPage.vue posts when an admin rotates the key: the
        # redacted config, so `app_secret` is absent and before_save restores it.
        channel.provider_config = channel.provider_config_without_app_secrets.merge('api_key' => 'rotated-token')

        expect(channel).to be_valid
        expect(a_request(:get, debug_token_url)).not_to have_been_made
      end
    end
  end

  context 'when the installation has no app secret' do
    it 'keeps upstream behavior and makes no Graph call' do
      expect(manual_channel).to be_valid
      expect(a_request(:get, debug_token_url)).not_to have_been_made
    end
  end
end
