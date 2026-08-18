# Headless MFA enrollment for a Super Admin operator, run on the host by
# whoever holds host access (there is no self-serve UI for this scope — see
# docs/fork/SUPER_ADMIN.md §4.0). Pairs with the flag-gated enforcement in
# custom/app/controllers/custom/super_admin/devise/sessions_controller.rb
# (SUPER_ADMIN_ENFORCE_MFA): once an operator is enrolled here, turning that
# flag on requires their TOTP/backup code on every future login.
#
# Uses the upstream Mfa::ManagementService for every OTP operation (secret
# generation, activation, backup codes, provisioning URI) — nothing here
# hand-rolls TOTP. The provisioning URI comes out already branded, because
# Mfa::ManagementService already carries the fork's issuer override
# (custom/app/services/custom/mfa/management_service.rb, wired via the
# existing `Mfa::ManagementService.prepend_mod_with(...)` hook) — this file
# doesn't need its own prepend.
#
# Idempotent-safe like the sibling bootstrap task (see
# Custom::SuperAdminBootstrap#truthy? for the identical flag-truthiness
# idiom): re-running against an already-enrolled operator is a refused no-op
# unless SUPER_ADMIN_MFA_ROTATE=true is set, in which case it's an explicit
# rotate — a fresh secret + fresh backup codes.
#
# The provisioning URI and backup codes are returned on the Result, never
# logged (they're the equivalent of a credential — CLAUDE.md §12 "never log
# access tokens or secret headers"). Only the rake shim prints them, straight
# to $stdout via `puts`, bypassing Rails.logger entirely so they never reach
# a log aggregator. That's the "printed ONCE" contract.
#
# Invoked by `rake fork:super_admin:mfa_enroll` (lib/tasks/fork/super_admin.rake).
#
# Environment:
#   SUPER_ADMIN_MFA_EMAIL          (required to do anything) operator email —
#                                   must already exist as a SuperAdmin (this
#                                   task never creates the operator; see
#                                   fork:super_admin:bootstrap for that)
#   SUPER_ADMIN_MFA_ROTATE=true    rotate an ALREADY-enrolled operator
#                                   (issues a new secret + new backup codes;
#                                   the old ones stop working)
class Custom::SuperAdminMfaEnroll
  # Compact class form (Custom::SuperAdminMfaEnroll, not `module Custom; class
  # ...`) deliberately: it keeps `Custom` out of Module.nesting, so the bare
  # `SuperAdmin` / `Mfa::ManagementService` references below resolve to the
  # top-level model/service and not to the Custom::SuperAdmin / Custom::Mfa
  # *namespace* modules that the sibling super_admin/mfa overlays also define.
  Result = Struct.new(:status, :email, :provisioning_uri, :backup_codes, keyword_init: true)

  def self.run(env: ENV, logger: Rails.logger)
    new(env: env, logger: logger).run
  end

  def initialize(env: ENV, logger: Rails.logger)
    @env = env
    @logger = logger
  end

  def run
    email = presence(@env['SUPER_ADMIN_MFA_EMAIL'])
    unless email
      warn('SUPER_ADMIN_MFA_EMAIL not set — skipping Super Admin MFA enrollment.')
      return Result.new(status: :skipped_no_email)
    end

    admin = SuperAdmin.from_email(email)
    unless admin
      raise "Super Admin MFA enrollment failed: no Super Admin with email #{email}. " \
            'Provision the operator first with fork:super_admin:bootstrap.'
    end

    already_enrolled = admin.mfa_enabled?

    if already_enrolled && !truthy?(@env['SUPER_ADMIN_MFA_ROTATE'])
      info("Super Admin #{email} already has MFA enrolled — unchanged " \
           '(set SUPER_ADMIN_MFA_ROTATE=true to rotate).')
      return Result.new(status: :skipped, email: email)
    end

    enroll!(admin, rotating: already_enrolled)
  end

  private

  def enroll!(admin, rotating:)
    service = Mfa::ManagementService.new(user: admin)
    service.enable_two_factor! # (re)generates otp_secret
    service.verify_and_activate! # flips otp_required_for_login = true (idempotent)
    codes = service.generate_backup_codes! # always fresh codes on (re)enroll
    uri = service.two_factor_provisioning_uri

    status = rotating ? :rotated : :enrolled
    # No secret material in this line — see the file header on why the URI
    # and backup codes are only ever returned, never logged.
    info("#{rotating ? 'Rotated' : 'Enrolled'} MFA for Super Admin #{admin.email}.")

    Result.new(status: status, email: admin.email, provisioning_uri: uri, backup_codes: codes)
  end

  def presence(value)
    value.to_s.strip.presence
  end

  def truthy?(value)
    ActiveModel::Type::Boolean.new.cast(value)
  end

  def info(message)
    @logger.info("[SuperAdminMfaEnroll] #{message}")
  end

  def warn(message)
    @logger.warn("[SuperAdminMfaEnroll] #{message}")
  end
end
