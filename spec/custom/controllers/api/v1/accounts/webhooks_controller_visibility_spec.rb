require 'rails_helper'

# Fork override: the tenant-facing webhooks endpoint hides platform-managed
# infrastructure — the orchestrator-ingest webhook — from listing and from
# id-based lookup. See
# custom/app/controllers/custom/api/v1/accounts/webhooks_controller.rb.
#
# Two distinct harms motivated it:
#
#   * `_webhook.json.jbuilder` renders `json.secret`, and `WebhookPolicy#index?`
#     grants on `administrator?` — the role EVERY vendor is provisioned into. So
#     a tenant could read the HMAC key our own ingest verifies with, and mint
#     valid `X-Chatwoot-Signature` headers for their account.
#   * `destroy` resolved any row in the account, and the control plane's repair
#     path is gated on the STORED ciphertext being null — so a deleted webhook
#     was never re-created and that tenant's AI went dark permanently.
RSpec.describe 'Webhooks API (fork platform-managed visibility)', type: :request do
  let(:account) { create(:account) }
  let(:admin) { create(:user, account: account, role: :administrator) }

  # The control plane's ingest webhook, flagged as infrastructure.
  let!(:platform_webhook) do
    # `inbox_id: nil` — the factory defaults it to 1, a dangling id. The
    # association is `optional: true` so it validates either way, but the index
    # view calls `webhook.inbox` and a stale id is noise this spec does not need.
    create(:webhook, account: account, inbox_id: nil, platform_managed: true,
                     url: 'https://api.example.com/webhooks/chatwoot')
  end
  # An ordinary webhook the vendor created themselves.
  let!(:tenant_webhook) do
    create(:webhook, account: account, inbox_id: nil, url: 'https://vendor.example.com/hook')
  end

  # The control plane acts as its own platform-managed account_user; that is the
  # identity `platform_actor?` keys off, and it is persisted, not request-supplied.
  # Created for its SIDE EFFECT (it is what makes `platform_user` a platform
  # actor), never referenced by name — hence `before`, not `let!`.
  let(:platform_user) { create(:user) }

  before do
    create(:account_user, account: account, user: platform_user, role: :administrator,
                          platform_managed: true)
  end

  describe 'GET /api/v1/accounts/{account.id}/webhooks' do
    it 'omits the platform webhook from a tenant admin’s listing' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      ids = response.parsed_body['payload']['webhooks'].map { |w| w['id'] }
      expect(ids).to include(tenant_webhook.id)
      expect(ids).not_to include(platform_webhook.id)
    end

    it 'never exposes the platform webhook’s secret to a tenant' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: admin.create_new_auth_token, as: :json

      # The secret is the HMAC key our ingest verifies with. Asserted on the raw
      # body, not just the parsed ids: a future view change that leaked it under
      # a different key would still fail this.
      expect(response.body).not_to include(platform_webhook.secret)
    end

    it 'still shows the tenant their OWN webhook secret (shape is unchanged)' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: admin.create_new_auth_token, as: :json

      row = response.parsed_body['payload']['webhooks'].find { |w| w['id'] == tenant_webhook.id }
      expect(row['secret']).to eq(tenant_webhook.secret)
    end

    it 'shows everything to the platform actor, so the control plane can still adopt its secret' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: platform_user.create_new_auth_token, as: :json

      # `ChatwootProvisioningService.resolveWebhookSecret` lists webhooks and
      # adopts the one matching its ingest URL. Scoping this actor out would
      # break provisioning AND the divergence reconcile that depends on it.
      ids = response.parsed_body['payload']['webhooks'].map { |w| w['id'] }
      expect(ids).to include(platform_webhook.id, tenant_webhook.id)
    end

    # `_webhook.json.jbuilder` now serializes `platform_managed`
    # (CHATWOOT_ENGINE_INTEGRATION.md §12, 2026-08-17 amendment). The tenant
    # listing is already scoped to `platform_managed: false` rows only
    # (§12.1, above), so a tenant only ever sees `false` — this spec pins
    # that the value is present at all, not just that the row is hidden.
    it 'tells the tenant their own webhook is not platform-managed' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: admin.create_new_auth_token, as: :json

      row = response.parsed_body['payload']['webhooks'].find { |w| w['id'] == tenant_webhook.id }
      expect(row['platform_managed']).to be(false)
    end

    # This is the field the control plane's webhook sweep needs: it can only
    # distinguish "adopted, already flagged" from "adopted, still needs
    # healing" (§12.3) if the flag actually travels in the payload the
    # platform actor's token reads.
    it 'tells the platform actor which rows are platform-managed and which are not' do
      get "/api/v1/accounts/#{account.id}/webhooks",
          headers: platform_user.create_new_auth_token, as: :json

      webhooks = response.parsed_body['payload']['webhooks']
      platform_row = webhooks.find { |w| w['id'] == platform_webhook.id }
      tenant_row = webhooks.find { |w| w['id'] == tenant_webhook.id }

      expect(platform_row['platform_managed']).to be(true)
      expect(tenant_row['platform_managed']).to be(false)
    end
  end

  describe 'DELETE /api/v1/accounts/{account.id}/webhooks/{id}' do
    it 'refuses to delete the platform webhook (404) and leaves it intact' do
      delete "/api/v1/accounts/#{account.id}/webhooks/#{platform_webhook.id}",
             headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      expect(Webhook.exists?(platform_webhook.id)).to be(true)
    end

    it 'still deletes a webhook the tenant owns' do
      delete "/api/v1/accounts/#{account.id}/webhooks/#{tenant_webhook.id}",
             headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:success)
      expect(Webhook.exists?(tenant_webhook.id)).to be(false)
    end
  end

  describe 'PATCH /api/v1/accounts/{account.id}/webhooks/{id}' do
    it 'refuses to update the platform webhook (404)' do
      patch "/api/v1/accounts/#{account.id}/webhooks/#{platform_webhook.id}",
            params: { webhook: { url: 'https://attacker.example.com/hook' } },
            headers: admin.create_new_auth_token, as: :json

      expect(response).to have_http_status(:not_found)
      # Re-pointing it would be as damaging as deleting it: inbound events would
      # go somewhere else while our ingest waited.
      expect(platform_webhook.reload.url).to eq('https://api.example.com/webhooks/chatwoot')
    end
  end
end
