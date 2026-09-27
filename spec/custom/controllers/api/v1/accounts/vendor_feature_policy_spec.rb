require 'rails_helper'

# Custom::VendorFeaturePolicy: agent bots and AI integrations are platform-owned,
# so a vendor (an account administrator that is not platform-managed) can
# neither see nor use them, while the platform's service identity can. See
# docs/fork/VENDOR_FEATURE_POLICY.md.
RSpec.describe 'Vendor feature policy', type: :request do
  let(:account) { create(:account) }
  let(:vendor) { create(:user, account: account, role: :administrator) }
  let(:platform_user) { create(:user) }
  let(:inbox) { create(:inbox, account: account) }

  before do
    create(:account_user, account: account, user: platform_user, role: :administrator, platform_managed: true)
  end

  def expect_refused
    expect(response).to have_http_status(:forbidden)
    expect(response.parsed_body['error_code']).to eq('feature_managed_by_platform')
  end

  describe 'agent bots' do
    let!(:bot) { create(:agent_bot, account: account) }

    it 'refuses a vendor the bot list' do
      get "/api/v1/accounts/#{account.id}/agent_bots", headers: vendor.create_new_auth_token, as: :json

      expect_refused
    end

    it 'refuses a vendor creating a bot' do
      expect do
        post "/api/v1/accounts/#{account.id}/agent_bots",
             params: { name: 'Their bot', outgoing_url: 'https://vendor.example.com/bot' },
             headers: vendor.create_new_auth_token, as: :json
      end.not_to change(AgentBot, :count)

      expect_refused
    end

    it 'refuses a vendor deleting a bot' do
      delete "/api/v1/accounts/#{account.id}/agent_bots/#{bot.id}", headers: vendor.create_new_auth_token, as: :json

      expect_refused
      expect(AgentBot.exists?(bot.id)).to be(true)
    end

    it 'lets the platform identity list bots' do
      get "/api/v1/accounts/#{account.id}/agent_bots", headers: platform_user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(response.parsed_body.pluck('id')).to include(bot.id)
    end
  end

  describe 'the inbox bot setting' do
    let(:bot) { create(:agent_bot, account: account) }

    it 'refuses a vendor reading which bot answers an inbox' do
      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/agent_bot", headers: vendor.create_new_auth_token, as: :json

      expect_refused
    end

    it 'refuses a vendor putting a bot on an inbox' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: bot.id }, headers: vendor.create_new_auth_token, as: :json

      expect_refused
      expect(inbox.reload.agent_bot).to be_nil
    end

    it 'lets the platform identity put a bot on an inbox' do
      post "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}/set_agent_bot",
           params: { agent_bot: bot.id }, headers: platform_user.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(inbox.reload.agent_bot).to eq(bot)
    end

    it 'leaves the rest of the inbox API to the vendor' do
      get "/api/v1/accounts/#{account.id}/inboxes/#{inbox.id}", headers: vendor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
    end
  end

  describe 'AI integrations' do
    # Hooks created as fixtures below would otherwise call OpenAI to validate the key.
    before { allow(Integrations::Openai::KeyValidator).to receive(:valid?).and_return(true) }

    it 'drops OpenAI and Dialogflow from the integrations list, and keeps the rest' do
      get "/api/v1/accounts/#{account.id}/integrations/apps", headers: vendor.create_new_auth_token, as: :json

      ids = response.parsed_body['payload'].pluck('id')
      expect(ids).not_to include('openai', 'dialogflow')
      expect(ids).to include('webhook')
    end

    it 'refuses a vendor creating an OpenAI hook' do
      expect do
        post "/api/v1/accounts/#{account.id}/integrations/hooks",
             params: { hook: { app_id: 'openai', settings: { api_key: 'sk-test' } } },
             headers: vendor.create_new_auth_token, as: :json
      end.not_to change(Integrations::Hook, :count)

      expect_refused
    end

    it 'refuses a vendor creating a Dialogflow hook' do
      post "/api/v1/accounts/#{account.id}/integrations/hooks",
           params: { hook: { app_id: 'dialogflow', inbox_id: inbox.id, settings: { project_id: 'p' } } },
           headers: vendor.create_new_auth_token, as: :json

      expect_refused
    end

    it 'refuses a vendor invoking an OpenAI hook that already exists' do
      hook = create(:integrations_hook, :openai, account: account)

      post "/api/v1/accounts/#{account.id}/integrations/hooks/#{hook.id}/process_event",
           params: { event: 'rephrase', payload: { content: 'hi' } }, headers: vendor.create_new_auth_token, as: :json

      expect_refused
    end

    it 'refuses a vendor re-enabling an existing Dialogflow hook' do
      hook = create(:integrations_hook, :dialogflow, account: account, inbox: inbox, status: 'disabled')

      patch "/api/v1/accounts/#{account.id}/integrations/hooks/#{hook.id}",
            params: { status: 'enabled' }, headers: vendor.create_new_auth_token, as: :json

      expect_refused
      expect(hook.reload.status).to eq('disabled')
    end

    it 'lets a vendor delete an AI hook created before the policy' do
      hook = create(:integrations_hook, :openai, account: account)

      delete "/api/v1/accounts/#{account.id}/integrations/hooks/#{hook.id}", headers: vendor.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(Integrations::Hook.exists?(hook.id)).to be(false)
    end

    it 'leaves other integrations to the vendor' do
      post "/api/v1/accounts/#{account.id}/integrations/hooks",
           params: { hook: { app_id: 'slack', settings: {} } },
           headers: vendor.create_new_auth_token, as: :json

      expect(response.parsed_body['error_code']).not_to eq('feature_managed_by_platform')
    end
  end

  describe 'Integrations::Hook#disabled?' do
    it 'treats a stored-enabled Dialogflow hook as disabled, so it never fires' do
      hook = create(:integrations_hook, :dialogflow, account: account, inbox: inbox)

      expect(hook.status).to eq('enabled')
      expect(hook.disabled?).to be(true)
    end

    it 'leaves other hooks as stored' do
      expect(create(:integrations_hook, account: account).disabled?).to be(false)
    end
  end
end
