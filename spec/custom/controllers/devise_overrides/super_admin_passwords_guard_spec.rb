require 'rails_helper'

# Verifies the fix for the password-reset MFA bypass: devise_for :super_admins
# doesn't skip :recoverable, so stock Devise::PasswordsController is live at
# /super_admin/password — a second, independent login-shaped path that never
# passes through SuperAdmin::Devise::SessionsController#create at all. Left
# unguarded, a successful reset there auto-signs the resource in
# (resource_class.sign_in_after_reset_password, Devise's default), minting a
# full session with zero OTP involved regardless of SUPER_ADMIN_ENFORCE_MFA.
#
# custom/app/controllers/custom/devise_overrides/super_admin_passwords_guard.rb
# closes this (wired via config/initializers/custom_prepends.rb, since
# Devise::PasswordsController ships no prepend_mod_with hook of its own). See
# docs/fork/SUPER_ADMIN.md §4.3 and §4.0.
RSpec.describe 'Super Admin password-reset MFA guard', type: :request do
  let(:super_admin) { create(:super_admin, password: 'Password1!') }

  def raw_reset_token
    super_admin.send_reset_password_instructions
  end

  def reset_params(token, password: 'NewStr0ng!Pass9')
    { super_admin: { reset_password_token: token, password: password, password_confirmation: password } }
  end

  # Warden stores the authenticated scope's user key in the session under
  # this key; its presence/absence is the ground truth for "was a session
  # minted", independent of which page the response happens to redirect to
  # (avoids depending on Devise's generic after_sign_in_path_for resolution,
  # and avoids rendering any other super_admin page from within the spec).
  def super_admin_session_key_present?
    session['warden.user.super_admin.key'].present?
  end

  context 'when SUPER_ADMIN_ENFORCE_MFA is off (default)' do
    it 'resets the password and signs the operator in (unchanged upstream behavior)' do
      token = raw_reset_token
      put '/super_admin/password', params: reset_params(token)

      expect(super_admin.reload.valid_password?('NewStr0ng!Pass9')).to be(true)
      expect(super_admin_session_key_present?).to be(true)
    end
  end

  context 'when SUPER_ADMIN_ENFORCE_MFA is on' do
    around do |example|
      with_modified_env(SUPER_ADMIN_ENFORCE_MFA: 'true') { example.run }
    end

    it 'resets the password but does NOT mint a session — no bypass of MFA enforcement' do
      token = raw_reset_token
      put '/super_admin/password', params: reset_params(token)

      # The recovery path still works — the password really did change.
      expect(super_admin.reload.valid_password?('NewStr0ng!Pass9')).to be(true)

      # But no warden session was ever set for this scope...
      expect(super_admin_session_key_present?).to be(false)

      # ...and you're sent to sign-in, not the dashboard.
      expect(response).to redirect_to(new_super_admin_session_path)
    end
  end
end
