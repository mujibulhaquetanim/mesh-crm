require 'rails_helper'

# Fork override: the tenant-facing agents endpoint excludes platform-managed
# infrastructure users (the control plane's automation service admin + AI reply
# identity, ADR-0005/0006). See
# custom/app/controllers/custom/api/v1/accounts/agents_controller.rb.
RSpec.describe 'Agents API (fork platform-managed exclusion)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }
  # A platform-managed seat (infrastructure) on the same account.
  let(:infra_user) { create(:user) }
  let!(:infra_account_user) do
    create(:account_user, account: account, user: infra_user, role: :administrator, platform_managed: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/agents' do
    it 'lists only tenant seats, never platform-managed infrastructure' do
      get "/api/v1/accounts/#{account.id}/agents",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      ids = response.parsed_body.map { |a| a['id'] }
      expect(ids).to include(admin.id)
      expect(ids).not_to include(infra_user.id)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/agents/{id}' do
    it 'refuses to delete a platform-managed user (404), protecting infrastructure' do
      delete "/api/v1/accounts/#{account.id}/agents/#{infra_user.id}",
             headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(account.account_users.exists?(user_id: infra_user.id)).to be(true)
    end

    it 'still deletes a real tenant agent' do
      agent = create(:user, account: account, role: :agent)

      delete "/api/v1/accounts/#{account.id}/agents/#{agent.id}",
             headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(account.account_users.exists?(user_id: agent.id)).to be(false)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/agents (create guard count)' do
    it 'counts only tenant seats against the cap, not platform-managed infra' do
      # Plan allows 2 agents. Real seats = 1 (admin); the platform-managed infra
      # user must NOT consume a slot, so a create still succeeds. Before the fix
      # the raw account_user count (2) tripped the guard at 2/2.
      account.update!(limits: { agents: 2 })

      post "/api/v1/accounts/#{account.id}/agents",
           params: { agent: { name: 'Real Agent', email: "real-#{SecureRandom.hex(4)}@example.com", role: 'agent' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
    end

    it 'blocks a create once tenant seats reach the cap' do
      account.update!(limits: { agents: 1 })

      post "/api/v1/accounts/#{account.id}/agents",
           params: { agent: { name: 'Over Cap', email: "over-#{SecureRandom.hex(4)}@example.com", role: 'agent' } },
           headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:payment_required)
    end
  end

  describe 'POST /api/v1/accounts/{account.id}/agents/bulk_create (bulk-invite guard count)' do
    it 'counts only tenant seats against the cap, not platform-managed infra' do
      # Plan allows 2 agents. Real seats = 1 (admin); the platform-managed infra
      # user must NOT consume a slot, so bulk-inviting 1 more real agent still
      # succeeds. Before the fix the raw account_user count (2) tripped
      # `available_agent_count` to 0, 402ing the onboarding bulk-invite flow
      # even though only one billable seat was in use.
      account.update!(limits: { agents: 2 })
      # Fetched outside the `expect` block: `create_new_auth_token` lazily
      # persists `admin` on first use, which would otherwise leak into the
      # `change(User, :count)` delta below and mask the real assertion.
      headers = admin.create_new_auth_token

      expect do
        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ["bulk-#{SecureRandom.hex(4)}@example.com"] },
             headers: headers, as: :json
      end.to change(User, :count).by(1)

      expect(response).to have_http_status(:success)
    end

    it 'still blocks a bulk-invite once real seats would exceed the cap' do
      # Same plan/seat mix (1 real + 1 platform-managed infra, cap 2 -> only 1
      # real slot free), but this invite asks for 2 new real agents. The
      # filtered count must still enforce the cap against genuinely billable
      # seats -- excluding infra is not the same as never enforcing the cap.
      account.update!(limits: { agents: 2 })
      headers = admin.create_new_auth_token

      expect do
        post "/api/v1/accounts/#{account.id}/agents/bulk_create",
             params: { emails: ["bulk1-#{SecureRandom.hex(4)}@example.com", "bulk2-#{SecureRandom.hex(4)}@example.com"] },
             headers: headers, as: :json
      end.not_to change(User, :count)

      expect(response).to have_http_status(:payment_required)
    end
  end
end
