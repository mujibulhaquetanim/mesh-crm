# Fork task (net-new file — no upstream overlap, so upstream merges never conflict).
# Thin shim over the fork-owned Custom::SuperAdminBootstrap service; the logic +
# tests live in custom/ and spec/custom/. See docs/fork/SUPER_ADMIN.md §4.
#
#   bundle exec rails fork:super_admin:bootstrap
#
# Idempotent — wire it into the boot/deploy sequence (before `rails server`) so a
# fresh instance comes up with a real operator instead of the dev seed.
#
# Also: fork:super_admin:mfa_enroll — thin shim over Custom::SuperAdminMfaEnroll,
# enrolls/rotates MFA for an existing operator (SUPER_ADMIN_MFA_EMAIL). Pairs
# with the SUPER_ADMIN_ENFORCE_MFA login enforcement. See SUPER_ADMIN.md §4.
# The provisioning URI + backup codes are secrets: the service never logs them
# (Rails.logger routinely ships to a log aggregator in prod), so printing them
# — once, to this terminal only — is this task's job, via `puts` below.
namespace :fork do
  namespace :super_admin do
    desc 'Provision the platform Super Admin from env + apply baseline hardening (idempotent)'
    task bootstrap: :environment do
      Custom::SuperAdminBootstrap.run
    end

    desc 'Enroll or rotate MFA for an existing Super Admin operator (idempotent-safe)'
    task mfa_enroll: :environment do
      result = Custom::SuperAdminMfaEnroll.run

      case result.status
      when :skipped_no_email
        # A typo'd/unset SUPER_ADMIN_MFA_EMAIL must never look like success —
        # the service already logs this via Rails.logger, but that doesn't
        # always reach this terminal, and this task's whole point is to
        # exist right before someone flips SUPER_ADMIN_ENFORCE_MFA=true.
        puts "\nSUPER_ADMIN_MFA_EMAIL not set — nothing enrolled. Nobody is MFA-enrolled by this run."
      when :skipped
        puts "\n#{result.email} already has MFA enrolled — unchanged " \
             '(set SUPER_ADMIN_MFA_ROTATE=true to rotate).'
      else
        puts "\n#{result.status == :rotated ? 'Rotated' : 'Enrolled'} MFA for #{result.email}."
        puts "\nProvisioning URI — add it to an authenticator app now (shown ONCE):"
        puts result.provisioning_uri
        puts "\nBackup codes — store them securely (shown ONCE):"
        result.backup_codes.each { |code| puts code }
      end
    end
  end
end
