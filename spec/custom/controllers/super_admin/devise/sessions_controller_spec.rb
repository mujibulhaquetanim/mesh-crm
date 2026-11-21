require 'rails_helper'

# The fork's flag-gated half of super admin MFA
# (custom/app/controllers/custom/super_admin/devise/sessions_controller.rb):
# with SUPER_ADMIN_ENFORCE_MFA on, an operator WITHOUT 2FA is refused. An
# enrolled operator goes through upstream's own code step (#16461), which
# upstream's spec/controllers/super_admin/devise/sessions_controller_spec.rb
# covers in depth (invalid, blank, backup code, expiry, attempt cap); here it is
# only checked that the overlay does not get in its way.
RSpec.describe 'Super Admin MFA enforcement', type: :request do
  before do
    skip('Skipping since MFA is not configured in this environment') unless Chatwoot.encryption_configured?
  end

  let(:super_admin) { create(:super_admin, password: 'Password1!') }

  def sign_in_params
    { super_admin: { email: super_admin.email, password: 'Password1!' } }
  end

  def enroll!(admin)
    admin.enable_two_factor!
    admin.update!(otp_required_for_login: true)
  end

  def submit_code(code)
    post '/super_admin/sign_in', params: { super_admin: { otp_code: code } }
  end

  context 'when SUPER_ADMIN_ENFORCE_MFA is off (default)' do
    it 'signs an un-enrolled operator in with a password alone (unchanged behavior)' do
      post '/super_admin/sign_in', params: sign_in_params
      expect(response).to redirect_to(super_admin_root_path)
    end

    it "leaves an enrolled operator to upstream's code step" do
      enroll!(super_admin)
      post '/super_admin/sign_in', params: sign_in_params
      expect(response).to redirect_to(super_admin_session_path)

      submit_code(super_admin.current_otp)
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

      it 'signs in after the password and a valid code (upstream step, asked once)' do
        post '/super_admin/sign_in', params: sign_in_params
        expect(response).to redirect_to(super_admin_session_path)

        submit_code(super_admin.current_otp)
        expect(response).to redirect_to(super_admin_root_path)
      end

      it 'signs in with a backup code at the code step' do
        code = super_admin.generate_backup_codes!.first
        post '/super_admin/sign_in', params: sign_in_params

        submit_code(code)
        expect(response).to redirect_to(super_admin_root_path)
      end

      it 'never signs in on the password alone' do
        post '/super_admin/sign_in', params: sign_in_params
        expect(response).to redirect_to(super_admin_session_path)

        get '/super_admin'
        expect(response).not_to have_http_status(:success)
      end

      it 'refuses a wrong code' do
        post '/super_admin/sign_in', params: sign_in_params
        submit_code('000000')
        expect(response).to redirect_to(super_admin_session_path)
      end
    end

    context 'when the operator has not enrolled OTP' do
      it 'refuses with an actionable enrollment message and never creates a session' do
        post '/super_admin/sign_in', params: sign_in_params
        expect(response).to redirect_to(super_admin_session_path)
        follow_redirect!
        expect(response.body).to include('fork:super_admin:mfa_enroll')

        get '/super_admin'
        expect(response).not_to have_http_status(:success)
      end
    end

    it 'still refuses a bad password with the generic message (no info leak)' do
      post '/super_admin/sign_in', params: sign_in_params.tap { |p| p[:super_admin][:password] = 'wrong' }
      expect(response).to redirect_to(super_admin_session_path)
      follow_redirect!
      expect(response.body).to include('Invalid credentials')
    end
  end
end
