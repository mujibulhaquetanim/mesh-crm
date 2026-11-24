# The one place `SUPER_ADMIN_ENFORCE_MFA` is read.
#
# Read by the sign-in check, `Custom::SuperAdmin::Devise::SessionsController`,
# which refuses an operator without 2FA while the flag is on. It used to have
# two more readers that had to agree with it (a password-reset guard and an
# `otp_attempt` field on a shadowed sign-in page); upstream #16461 removed the
# password routes and added its own code step, so both were dropped. Kept as
# one predicate so a future reader cannot drift from the check.
#
# Deliberately re-reads ENV on every call (no memoization): the specs flip the
# flag per-example with ClimateControl (`with_modified_env`), and a cached
# value would let the first example that touched it decide the rest.
#
# Deliberately NOT GlobalConfig/InstallationConfig-backed. This is a
# deployment-level control for the platform operator console, so it must not be
# flippable from inside the console it protects — installation configs are
# editable at `/super_admin/installation_configs` by exactly the session this
# flag guards.
#
# Compact class form (`class Custom::SuperAdminMfa`, not `module Custom; class
# ...`) for the same reason `super_admin_mfa_enroll.rb` uses it — it keeps
# `Custom` out of `Module.nesting`.
class Custom::SuperAdminMfa
  # Same truthiness idiom as the sibling bootstrap flags
  # (`Custom::SuperAdminBootstrap#truthy?`): "true"/"1"/"t"/"on" are on;
  # unset, "false", "0", and anything unrecognised are off.
  #
  # Returns `nil` (not `false`) when the var is unset — every call site treats
  # the result as a truthy test.
  def self.enforced?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('SUPER_ADMIN_ENFORCE_MFA', nil))
  end
end
