require 'rails_helper'

# Fork: enrolls/rotates MFA for a Super Admin operator (headless, host-run).
# See custom/app/services/custom/super_admin_mfa_enroll.rb, the thin rake shim
# lib/tasks/fork/super_admin.rake (fork:super_admin:mfa_enroll), and
# docs/fork/SUPER_ADMIN.md §4.
RSpec.describe Custom::SuperAdminMfaEnroll do
  before do
    skip('Skipping since MFA is not configured in this environment') unless Chatwoot.encryption_configured?
  end

  let(:logger) { Logger.new(nil) }
  let!(:super_admin) { create(:super_admin, email: 'ops@company.com', password: 'Str0ng!Pass1') }

  def run(env)
    described_class.run(env: env, logger: logger)
  end

  it 'does nothing when SUPER_ADMIN_MFA_EMAIL is absent' do
    expect { run({}) }.not_to(change { super_admin.reload.otp_required_for_login? })
  end

  it 'fails loud for an unknown operator email' do
    expect do
      run('SUPER_ADMIN_MFA_EMAIL' => 'nobody@company.com')
    end.to raise_error(/no Super Admin/i)
  end

  it 'enrolls an un-enrolled operator: activates MFA and prints the URI + backup codes once' do
    result = run('SUPER_ADMIN_MFA_EMAIL' => super_admin.email)

    super_admin.reload
    expect(super_admin.otp_required_for_login?).to be(true)
    expect(super_admin.otp_secret).to be_present
    expect(result.status).to eq(:enrolled)
    expect(result.provisioning_uri).to include('otpauth://')
    expect(result.backup_codes.size).to eq(10)
  end

  it 'is idempotent-safe: re-running without rotate on an already-enrolled operator refuses (no-op)' do
    run('SUPER_ADMIN_MFA_EMAIL' => super_admin.email)
    original_secret = super_admin.reload.otp_secret

    result = run('SUPER_ADMIN_MFA_EMAIL' => super_admin.email)

    expect(result.status).to eq(:skipped)
    expect(super_admin.reload.otp_secret).to eq(original_secret)
  end

  it 'rotates when SUPER_ADMIN_MFA_ROTATE=true, issuing a new secret and new backup codes' do
    first = run('SUPER_ADMIN_MFA_EMAIL' => super_admin.email)
    original_secret = super_admin.reload.otp_secret

    second = run('SUPER_ADMIN_MFA_EMAIL' => super_admin.email, 'SUPER_ADMIN_MFA_ROTATE' => 'true')

    expect(second.status).to eq(:rotated)
    expect(super_admin.reload.otp_secret).not_to eq(original_secret)
    expect(second.backup_codes).not_to eq(first.backup_codes)
  end
end
