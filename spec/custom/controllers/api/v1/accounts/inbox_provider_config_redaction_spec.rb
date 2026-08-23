require 'rails_helper'

# Fork override: the inbox API redacts Meta app secrets from a WhatsApp
# channel's `provider_config`.
#
# `_inbox.json.jbuilder` serializes the whole jsonb bag to any account
# ADMINISTRATOR — the role every vendor on this platform is provisioned into —
# on both index and show. Four of its keys are what
# `MetaTokenVerifyConcern` verifies inbound webhook signatures with, and a Meta
# app secret is app-wide: one tenant admin holding it can forge
# `X-Hub-Signature-256` for every other tenant's inbox on the same Meta app.
#
# `api_key` stays visible — it is the channel's own send token, scoped to that
# one WABA, and the dashboard reads it back.
#
# See custom/app/models/custom/channel/whatsapp.rb.
RSpec.describe 'Inbox API (fork provider_config redaction)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  let(:agent) { create(:user, account: account, role: :agent) }

  let(:app_secrets) do
    { 'app_secret' => 'meta-app-secret-value',
      'app_secret_key' => 'meta-app-secret-key-value',
      'client_secret' => 'meta-client-secret-value',
      'api_secret' => 'meta-api-secret-value' }
  end

  # Secrets are written AFTER create so the factory's own provider_config merge
  # cannot overwrite them, and so no create-time webhook registration fires.
  let(:whatsapp_channel) do
    channel = create(:channel_whatsapp, account: account, provider: 'whatsapp_cloud',
                                        sync_templates: false, validate_provider_config: false)
    channel.update!(provider_config: channel.provider_config.merge(app_secrets))
    channel
  end
  let(:inbox) { whatsapp_channel.inbox }

  def provider_config_from(payload)
    payload['provider_config']
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes' do
    it 'omits every Meta app secret key for an administrator' do
      get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      payload = response.parsed_body['payload'].find { |item| item['id'] == inbox.id }
      expect(provider_config_from(payload).keys).not_to include(*app_secrets.keys)
    end

    it 'still returns the non-secret provider config an administrator needs' do
      get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json

      payload = response.parsed_body['payload'].find { |item| item['id'] == inbox.id }
      config = provider_config_from(payload)
      expect(config['phone_number_id']).to eq(whatsapp_channel.provider_config['phone_number_id'])
      expect(config['business_account_id']).to eq(whatsapp_channel.provider_config['business_account_id'])
      expect(config['webhook_verify_token']).to eq(whatsapp_channel.provider_config['webhook_verify_token'])
      # The channel's own send token — scoped to this WABA, read back by the
      # dashboard, and deliberately NOT redacted.
      expect(config['api_key']).to eq(whatsapp_channel.provider_config['api_key'])
    end

    it 'leaks no secret VALUE anywhere in the response body' do
      get "/api/v1/accounts/#{account.id}/inboxes", headers: admin.create_new_auth_token, as: :json

      # Asserted on the raw body, not the parsed hash: a secret that reaches the
      # wire under any other key is the same disclosure.
      app_secrets.each_value { |secret| expect(response.body).not_to include(secret) }
    end

    it 'still returns no provider config at all to an agent' do
      create(:inbox_member, user: agent, inbox: inbox)

      get "/api/v1/accounts/#{account.id}/inboxes", headers: agent.create_new_auth_token, as: :json

      expect(response.body).not_to include('provider_config')
    end
  end

  describe 'GET /api/v1/accounts/{account.id}/inboxes/{inbox.id}' do
    it 'omits every Meta app secret key on show as well' do
      # index and show render the same partial, but only one of them was the
      # reported path — pin both so a future divergence is caught.
      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}", headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(provider_config_from(response.parsed_body).keys).not_to include(*app_secrets.keys)
      app_secrets.each_value { |secret| expect(response.body).not_to include(secret) }
    end
  end
end
