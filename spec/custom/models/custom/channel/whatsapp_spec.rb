require 'rails_helper'

# Unit coverage for the two halves of custom/app/models/custom/channel/whatsapp.rb:
# what leaves the server (`#provider_config_without_app_secrets`) and what
# survives a write that omits it (`before_save :retain_stored_meta_app_secrets`).
#
# The second half is not a nicety. `provider_config` is a jsonb column the inbox
# controller replaces WHOLESALE, and the dashboard edits it by read-modify-write
# (`{ ...inbox.provider_config, api_key: newKey }`). Redacting the read without
# protecting the write would mean an admin rotating the API key silently erases
# the channel's app secret — switching webhook verification off with no error.
RSpec.describe Channel::Whatsapp do
  let(:app_secret) { 'meta-app-secret-value' }

  # Secrets are written after create: the factory merges its own defaults over
  # whatever provider_config is passed in, and creating with a non-embedded
  # source would fire the real webhook-registration call.
  let(:channel) do
    channel = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
    channel.update!(provider_config: channel.provider_config.merge('app_secret' => app_secret))
    channel
  end

  describe '#provider_config_without_app_secrets' do
    it 'drops every key MetaTokenVerifyConcern treats as an app secret' do
      channel.update!(
        provider_config: channel.provider_config.merge(
          'app_secret_key' => 'a', 'client_secret' => 'b', 'api_secret' => 'c'
        )
      )

      expect(channel.provider_config_without_app_secrets.keys)
        .not_to include(*MetaTokenVerifyConcern::CHANNEL_APP_SECRET_KEYS)
    end

    it 'keeps the send token and every other non-secret key' do
      config = channel.provider_config_without_app_secrets

      expect(config['api_key']).to eq(channel.provider_config['api_key'])
      expect(config['phone_number_id']).to eq(channel.provider_config['phone_number_id'])
      expect(config['webhook_verify_token']).to be_present
    end

    it 'does not mutate the stored config' do
      channel.provider_config_without_app_secrets

      expect(channel.reload.provider_config['app_secret']).to eq(app_secret)
    end
  end

  describe 'retaining stored app secrets on write' do
    it 'survives the dashboard round trip that writes the redacted config back' do
      # Exactly what ConfigurationPage.vue posts when an admin rotates the key.
      rotated = channel.provider_config_without_app_secrets.merge('api_key' => 'rotated-token')

      channel.update!(provider_config: rotated)

      expect(channel.reload.provider_config['api_key']).to eq('rotated-token')
      expect(channel.provider_config['app_secret']).to eq(app_secret)
    end

    it 'survives a write that skips validations' do
      # The voice toggles use save!(validate: false), which is why this is a
      # before_save rather than a before_validation.
      channel.provider_config = channel.provider_config_without_app_secrets.merge('calling_enabled' => true)
      channel.save!(validate: false)

      expect(channel.reload.provider_config['app_secret']).to eq(app_secret)
    end

    it 'still clears the secret when the key is sent explicitly blank' do
      # Removal has to stay possible — it just has to be deliberate.
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => ''))

      expect(channel.reload.provider_config['app_secret']).to be_blank
    end

    it 'still replaces the secret when a new value is sent' do
      channel.update!(provider_config: channel.provider_config.merge('app_secret' => 'rotated-secret'))

      expect(channel.reload.provider_config['app_secret']).to eq('rotated-secret')
    end

    it 'leaves a config with no stored secrets exactly as written' do
      plain = create(:channel_whatsapp, provider: 'whatsapp_cloud', sync_templates: false, validate_provider_config: false)
      new_config = plain.provider_config.merge('api_key' => 'new_key')

      plain.update!(provider_config: new_config)

      expect(plain.reload.provider_config).to eq(new_config)
    end
  end

  describe 'other channel types' do
    it 'leaves Bandwidth SMS provider_config untouched' do
      # Channel::Sms stores its OWN api_secret there and authenticates outbound
      # sends with it; the overlay is scoped to Channel::Whatsapp, and
      # _inbox.json.jbuilder only serializes provider_config for WhatsApp.
      sms_channel = create(:channel_sms)

      expect(sms_channel).not_to respond_to(:provider_config_without_app_secrets)
      expect(sms_channel.reload.provider_config['api_secret']).to eq('1')
    end
  end
end
