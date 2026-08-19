require 'rails_helper'

# The operator's password-recovery PAGES must actually render.
#
# They did not, in every environment, from the moment the fork existed:
# Devise's shared `_links` partial (rendered by both pages) iterates
# `resource_class.omniauth_providers` — `[:google_oauth2, :saml]` on
# SuperAdmin < User — and calls `omniauth_authorize_path`. Chatwoot registers
# those providers as OmniAuth::Builder MIDDLEWARE rather than through
# `Devise.setup`, so `Devise.omniauth_configs` is empty, Devise generated no
# omniauth routes, and that helper does not exist → NoMethodError → 500.
#
# `custom/app/views/devise/shared/_links.html.erb` intersects the provider list
# with `Devise.omniauth_configs.keys`. See docs/fork/SUPER_ADMIN.md §4.0.
#
# Worth stating plainly: this is a usability + honesty fix, NOT a posture
# change. POST/PUT /super_admin/password never load this partial and were live
# the whole time (they answer 302), so the 500 only ever blocked the operator's
# browser — never an attacker. The MFA session guard on the reset flow is
# unchanged and covered by super_admin_passwords_guard_spec.rb.
RSpec.describe 'Super Admin password recovery pages', type: :request do
  let(:super_admin) { create(:super_admin, password: 'Password1!') }

  describe 'GET /super_admin/password/new' do
    it 'renders the "forgot your password" form' do
      get '/super_admin/password/new'

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('super_admin[email]')
    end
  end

  describe 'GET /super_admin/password/edit' do
    it 'renders the "set a new password" form for a valid reset token' do
      token = super_admin.send_reset_password_instructions

      get "/super_admin/password/edit?reset_password_token=#{token}"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include('super_admin[password]')
    end
  end

  describe 'the links partial itself' do
    it 'renders no omniauth button while Devise has no omniauth config' do
      # Guards the actual failure mode rather than just the status code: a
      # future change that puts these providers into Devise.setup would make
      # the button legitimate, but until then rendering one means the helper
      # was called and the page is about to 500.
      expect(Devise.omniauth_configs).to be_empty

      get '/super_admin/password/new'

      expect(response.body).not_to include('Sign in with')
    end

    it 'does NOT link to registration, which this scope no longer routes' do
      get '/super_admin/password/new'

      expect(response.body).not_to include('Sign up')
    end
  end
end
