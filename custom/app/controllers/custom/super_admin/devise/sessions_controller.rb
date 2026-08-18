# The `/super_admin` console is the highest-blast-radius login in the fleet — a
# session here can read/change every tenant's data and mint the
# `PLATFORM_TOKEN` (docs/fork/SUPER_ADMIN.md §1). Upstream's `valid_credentials?`
# checks `valid_password?` only; the `otp_*` columns on `users` exist but were
# never consulted on this path (SUPER_ADMIN.md §3 / §5 item 7).
#
# Behind SUPER_ADMIN_ENFORCE_MFA (same ENV-var + truthiness idiom as the sibling
# bootstrap flags SUPER_ADMIN_REMOVE_DEFAULT_SEED / SUPER_ADMIN_DISABLE_SIGNUP —
# see Custom::SuperAdminBootstrap#truthy?):
#   - Enrolled operator: password + a valid TOTP (the `otp_attempt` sign-in form
#     field) or a valid backup code are both required. Verification is
#     delegated entirely to the upstream Mfa::AuthenticationService
#     (validate_and_consume_otp! / Mfa::ManagementService#validate_backup_code!)
#     — nothing here hand-rolls TOTP or backup-code checking.
#   - Un-enrolled operator: fail CLOSED. Password alone must never mint a
#     `super_admin` session while the flag is on — refused with an actionable
#     message naming the enrollment task (`fork:super_admin:mfa_enroll`).
#     Recovery is host access, per SUPER_ADMIN.md's documented recovery story.
#   - Wrong/missing OTP renders the exact same generic message as a bad
#     password, so the response never reveals whether an email has MFA
#     enrolled. The enrollment-required message is the one deliberate
#     exception — it is the actionable recovery path, not a leak (an attacker
#     without the correct password never reaches this branch).
#
# Inert by default: with the flag unset, `super` is a straight pass-through to
# upstream's password-only check, so behaviour and specs are byte-identical to
# today. rack_attack throttles `POST /super_admin/sign_in` by IP and email at
# the route level (config/initializers/rack_attack.rb), independent of this
# controller, so throttling still applies with the flag on.
module Custom::SuperAdmin::Devise::SessionsController
  private

  def valid_credentials?
    return super unless mfa_enforced?
    return false unless super # password check + @super_admin lookup (upstream)

    return refuse_unenrolled! unless @super_admin.mfa_enabled?
    return refuse_invalid! unless mfa_otp_valid?

    true
  end

  def mfa_enforced?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('SUPER_ADMIN_ENFORCE_MFA', nil))
  end

  # Single sign-in-form field (`otp_attempt`) that accepts either a TOTP code
  # or a backup code. Both branches reuse the upstream service — this just
  # decides which upstream check to try, it doesn't verify anything itself.
  def mfa_otp_valid?
    attempt = params.dig(:super_admin, :otp_attempt)
    return false if attempt.blank?

    Mfa::AuthenticationService.new(user: @super_admin, otp_code: attempt).authenticate ||
      Mfa::AuthenticationService.new(user: @super_admin, backup_code: attempt).authenticate
  end

  def refuse_unenrolled!
    @error_message =
      'MFA enrollment required for this account. Ask an operator with host access to run ' \
      '`bundle exec rails fork:super_admin:mfa_enroll` (see docs/fork/SUPER_ADMIN.md §4).'
    false
  end

  def refuse_invalid!
    @error_message = 'Invalid credentials. Please try again.'
    false
  end
end
