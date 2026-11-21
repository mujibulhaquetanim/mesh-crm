require 'rails_helper'

# Fork regression guard: the Platform
# API — the ONLY path the control plane uses to provision tenant users
# (`POST /platform/api/v1/users`)
# — must never be able to mint a `SuperAdmin`. `SuperAdmin` is STI on the same
# `users` table as tenant agents (`type` column) and guards the whole-instance
# `/super_admin` console with a password-only login (no MFA). If a tenant-facing create path could set
# `type`, a vendor with nothing but their own provisioning request could hand
# themselves cross-tenant control of the entire installation.
#
# Investigated first (not assumed): `Platform::Api::V1::UsersController#user_params`
# (`app/controllers/platform/api/v1/users_controller.rb:54-56`) is
#   params.permit(:name, :display_name, :email, :password, custom_attributes: {})
# — `type` is not in the permit list, so Rails strong params silently drops it
# from `params.permit(...)` (no `require` wrapper to raise on it) regardless of
# what the caller sends. This is already-safe upstream behavior, not a fork
# fix; this spec exists to fail loudly if a future permitted-param widening
# (upstream merge or local change) ever adds `type` back in.
RSpec.describe 'Platform Users API (super admin privilege separation)', type: :request do
  let(:platform_app) { create(:platform_app) }
  let(:auth_headers) { { api_access_token: platform_app.access_token.token } }

  describe 'POST /platform/api/v1/users' do
    it 'cannot mint a SuperAdmin even when type is explicitly passed in params' do
      expect do
        post '/platform/api/v1/users',
             params: { name: 'Attempted Escalation', email: 'escalate@vendor.example.com',
                       password: 'Password1!', type: 'SuperAdmin' },
             headers: auth_headers, as: :json
      end.not_to change(SuperAdmin, :count)

      expect(response).to have_http_status(:success)

      created = User.find_by(email: 'escalate@vendor.example.com')
      expect(created).to be_present
      # STI: a plain User row (`type` NULL), not promoted to the SuperAdmin
      # subclass, regardless of the `type: 'SuperAdmin'` the request sent.
      expect(created.type).to be_nil
      expect(created).not_to be_a(SuperAdmin)
      expect(SuperAdmin.exists?(email: 'escalate@vendor.example.com')).to be(false)
    end

    # NOT a second exercise of the strong-params strip above: on the found-user
    # branch `user_params` is used only to look up the email and is never
    # assigned onto the user. So this pins a stronger invariant: an existing
    # user's `type` cannot be touched through this path at all. Upstream #16530
    # (2026-11-21 sync) also refuses (401) a found user the calling platform
    # app does not manage; both branches are pinned.
    it 'leaves an existing user’s type untouched — the found-user branch applies no attributes at all' do
      existing = create(:user, email: 'already-here@vendor.example.com')
      create(:platform_app_permissible, platform_app: platform_app, permissible: existing)

      post '/platform/api/v1/users',
           params: { name: 'Attempted Escalation', email: 'already-here@vendor.example.com',
                     password: 'Password1!', type: 'SuperAdmin' },
           headers: auth_headers, as: :json

      expect(response).to have_http_status(:success)
      expect(existing.reload.type).to be_nil
    end

    it 'refuses an existing user the platform app does not manage, and leaves its type untouched' do
      existing = create(:user, email: 'not-ours@vendor.example.com')

      post '/platform/api/v1/users',
           params: { name: 'Attempted Escalation', email: 'not-ours@vendor.example.com',
                     password: 'Password1!', type: 'SuperAdmin' },
           headers: auth_headers, as: :json

      expect(response).to have_http_status(:unauthorized)
      expect(existing.reload.type).to be_nil
    end
  end

  describe 'the tenant population created through normal provisioning' do
    it 'gives a factory-provisioned tenant user a nil type — never SuperAdmin' do
      account = create(:account)
      tenant_user = create(:user, account: account, role: :administrator)

      expect(tenant_user.type).to be_nil
      expect(tenant_user).not_to be_a(SuperAdmin)
      expect(SuperAdmin.exists?(tenant_user.id)).to be(false)
    end
  end
end
