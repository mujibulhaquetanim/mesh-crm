# The `/super_admin` console is the highest-blast-radius login in the fleet — a
# session here can read/change every tenant's data and mint the
# `PLATFORM_TOKEN`.
#
# Upstream (#16461) now asks an ENROLLED operator for an authenticator or
# backup code as a second step (`start_mfa_challenge` → `verify_mfa_code`).
# It still lets an operator WITHOUT 2FA in on a password alone. This overlay
# adds only that missing half, behind SUPER_ADMIN_ENFORCE_MFA (read through
# Custom::SuperAdminMfa.enforced?, the single reader of the flag):
#
#   - Un-enrolled operator, flag on: fail CLOSED. A password alone must never
#     mint a `super_admin` session — refused with an actionable message naming
#     the enrollment task (`fork:super_admin:mfa_enroll`). Recovery is host
#     access.
#   - Enrolled operator: untouched. Upstream's code step runs as it ships.
#
# The fork used to check the code in the SAME form (an `otp_attempt` field on a
# shadowed sign-in page). Upstream's two-step flow replaced that; keeping both
# would ask an enrolled operator for a code twice, and the shadowed page had no
# field for upstream's second step at all.
#
# Inert by default: with the flag unset, `super` is a straight pass-through.
# rack_attack throttles `POST /super_admin/sign_in` by IP, email and code step
# (config/initializers/rack_attack.rb, upstream), independent of this module.
module Custom::SuperAdmin::Devise::SessionsController
  private

  def valid_credentials?
    return super unless Custom::SuperAdminMfa.enforced?
    return false unless super # password check + @super_admin lookup (upstream)
    return refuse_unenrolled! unless @super_admin.mfa_enabled?

    true
  end

  def refuse_unenrolled!
    @error_message =
      'MFA enrollment required for this account. Ask an operator with host access to run ' \
      '`bundle exec rails fork:super_admin:mfa_enroll`.'
    false
  end
end
