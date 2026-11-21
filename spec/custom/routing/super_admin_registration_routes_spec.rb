require 'rails_helper'

# `SuperAdmin < User` and User is `:registerable` and `:recoverable`, so a bare
# `devise_for :super_admins` would route a self-signup surface (an
# unauthenticated GET /super_admin/sign_up + POST /super_admin, and a DELETE
# /super_admin that deletes the operator's own account) and a password-reset
# surface onto the operator console. The fork skipped registrations first;
# upstream (#16461) now skips registrations, passwords and confirmations.
#
# These examples pin that the whole surface stays unrouted, because the fork
# dropped its own guards for it once upstream removed the routes:
# Custom::DeviseOverrides::SuperAdminPasswordsGuard (a password reset signed the
# operator in without the MFA check), the `super_admin_password/*` throttles,
# and the devise/shared/_links shadow those pages needed. If a future upstream
# sync routes any of it again, this file goes red before those guards are
# missed.
RSpec.describe 'Super Admin registration routes', type: :request do
  describe 'the self-signup surface' do
    it 'does not route GET /super_admin/sign_up' do
      get '/super_admin/sign_up'

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route POST /super_admin (registrations#create)' do
      post '/super_admin', params: { super_admin: { email: 'x@example.com', password: 'Password1!' } }

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route GET /super_admin/cancel' do
      get '/super_admin/cancel'

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route DELETE /super_admin (registrations#destroy — self account deletion)' do
      delete '/super_admin'

      expect(response).to have_http_status(:not_found)
    end

    it 'leaves the registration route out of the devise mapping' do
      expect(Devise.mappings[:super_admin].used_routes).not_to include(:registration)
    end
  end

  describe 'the password-recovery and confirmation surface' do
    it 'does not route GET /super_admin/password/new' do
      get '/super_admin/password/new'

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route POST /super_admin/password (reset request)' do
      post '/super_admin/password', params: { super_admin: { email: 'x@example.com' } }

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route PUT /super_admin/password (token submission that used to sign in)' do
      put '/super_admin/password', params: { super_admin: { reset_password_token: 'x', password: 'Password1!' } }

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route GET /super_admin/confirmation' do
      get '/super_admin/confirmation'

      expect(response).to have_http_status(:not_found)
    end

    it 'leaves password, confirmation and registration out of the devise mapping' do
      expect(Devise.mappings[:super_admin].used_routes).not_to include(:password, :confirmation, :registration)
    end

    it 'no longer defines the registration route helper at all' do
      expect { Rails.application.routes.url_helpers.new_super_admin_registration_path }
        .to raise_error(NoMethodError)
    end
  end
end
