require 'rails_helper'

# Verifies the fork's flag-gated MFA enforcement on the highest-blast-radius
# login in the fleet (custom/app/controllers/custom/super_admin/devise/sessions_controller.rb).
# See docs/fork/SUPER_ADMIN.md §3 ("MFA enforced on login") + §4 (runbook).
RSpec.describe 'Super Admin MFA enforcement', type: :request do
  before do
    skip('Skipping since MFA is not configured in this environment') unless Chatwoot.encryption_configured?
  end

  let(:super_admin) { create(:super_admin, password: 'Password1!') }

  def sign_in_params(otp_attempt: nil)
    { super_admin: { email: super_admin.email, password: 'Password1!', otp_attempt: otp_attempt }.compact }
  end

  def enroll!(admin)
    admin.enable_two_factor!
    admin.update!(otp_required_for_login: true)
  end

  context 'when SUPER_ADMIN_ENFORCE_MFA is off (default)' do
    it 'signs in with password alone (unchanged behavior)' do
      post '/super_admin/sign_in', params: sign_in_params
      expect(response).to redirect_to(super_admin_root_path)
    end

    it 'signs in with password alone even when the operator has OTP enrolled (flag off = inert)' do
      enroll!(super_admin)
      post '/super_admin/sign_in', params: sign_in_params
      expect(response).to redirect_to(super_admin_root_path)
    end

    it 'still refuses a bad password the same way as before' do
      post '/super_admin/sign_in', params: sign_in_params.tap { |p| p[:super_admin][:password] = 'wrong' }
      expect(response).to redirect_to(super_admin_session_path)
    end
  end

  context 'when SUPER_ADMIN_ENFORCE_MFA is on' do
    around do |example|
      with_modified_env(SUPER_ADMIN_ENFORCE_MFA: 'true') { example.run }
    end

    context 'when the operator has OTP enrolled' do
      before { enroll!(super_admin) }

      it 'creates a session for password + valid TOTP' do
        post '/super_admin/sign_in', params: sign_in_params(otp_attempt: super_admin.current_otp)
        expect(response).to redirect_to(super_admin_root_path)
      end

      it 'creates a session for password + a valid backup code' do
        codes = super_admin.generate_backup_codes!
        post '/super_admin/sign_in', params: sign_in_params(otp_attempt: codes.first)
        expect(response).to redirect_to(super_admin_root_path)
      end

      it 'refuses password + wrong TOTP with the same generic message as a bad password' do
        post '/super_admin/sign_in', params: sign_in_params(otp_attempt: '000000')
        expect(response).to redirect_to(super_admin_session_path)
        follow_redirect!
        expect(response.body).to include('Invalid credentials')
      end

      it 'refuses password + missing TOTP (password alone never signs in)' do
        post '/super_admin/sign_in', params: sign_in_params
        expect(response).to redirect_to(super_admin_session_path)
      end
    end

    context 'when the operator has not enrolled OTP' do
      it 'refuses with an actionable enrollment message and never creates a session' do
        post '/super_admin/sign_in', params: sign_in_params
        expect(response).to redirect_to(super_admin_session_path)
        follow_redirect!
        expect(response.body).to include('fork:super_admin:mfa_enroll')
      end
    end

    it 'still refuses a bad password with the generic message (throttle-safe, no info leak)' do
      post '/super_admin/sign_in', params: sign_in_params.tap { |p| p[:super_admin][:password] = 'wrong' }
      expect(response).to redirect_to(super_admin_session_path)
    end
  end
end
