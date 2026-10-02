require 'rails_helper'

# custom/app/controllers/custom/account_limits_controller.rb, routed by
# config/initializers/custom_routes.rb. The path is the one the dashboard's
# quota UI already calls; the fork serves it on the MIT core, with or without an
# enterprise folder present.
RSpec.describe 'Account limits (fork quota endpoint)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  describe 'GET /enterprise/api/v1/accounts/{account.id}/limits' do
    it 'serves limits on self-hosted installs with every quota resource' do
      account.update!(limits: { teams: 2 })
      create(:team, account: account)

      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      limits = response.parsed_body['limits']
      expect(limits['teams']).to eq('allowed' => 2, 'consumed' => 1)
      expect(limits.keys).to include('agents', 'inboxes', 'webhooks', 'agent_bots', 'labels',
                                     'custom_attribute_definitions', 'automation_rules', 'integrations')
    end

    it 'counts only tenant seats for agents.consumed, excluding platform-managed infra' do
      account.update!(limits: { agents: 3 })
      # One real seat (admin) + one platform-managed infrastructure user.
      infra = create(:user)
      create(:account_user, account: account, user: infra, role: :administrator, platform_managed: true)

      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['limits']['agents']).to eq('allowed' => 3, 'consumed' => 1)
    end

    it 'marks unconfigured resources as unlimited via a null allowance' do
      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['limits']['labels']).to eq('allowed' => nil, 'consumed' => 0)
    end

    it 'surfaces the externally-enforced agentic_ai limit when a cap is set' do
      account.update!(limits: { agentic_ai: 500 }, custom_attributes: { agentic_ai_usage: 500 })

      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['limits']['agentic_ai']).to eq('allowed' => 500, 'consumed' => 500)
    end

    it 'omits agentic_ai when no cap is provisioned' do
      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: admin.create_new_auth_token, as: :json

      expect(response.parsed_body['limits']).not_to have_key('agentic_ai')
    end

    it 'requires authentication' do
      get "/enterprise/api/v1/accounts/#{account.id}/limits", as: :json

      expect(response).to have_http_status(:unauthorized)
    end

    it 'is served by the fork controller, not an enterprise one' do
      expect(Rails.application.routes.recognize_path("/enterprise/api/v1/accounts/#{account.id}/limits"))
        .to include(controller: 'custom/account_limits', action: 'show')
    end

    it 'refuses a user from another account' do
      outsider = create(:user, account: create(:account), role: :administrator)

      get "/enterprise/api/v1/accounts/#{account.id}/limits",
          headers: outsider.create_new_auth_token, as: :json

      expect(response).to have_http_status(:unauthorized)
    end
  end
end
