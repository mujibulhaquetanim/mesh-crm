# The one place `SUPER_ADMIN_ENFORCE_MFA` is read.
#
# Three independent surfaces have to agree on whether enforcement is on, and
# each is reached by a completely different code path:
#
#   1. the sign-in check — `Custom::SuperAdmin::Devise::SessionsController`
#   2. the password-reset guard — `Custom::DeviseOverrides::SuperAdminPasswordsGuard`
#   3. the sign-in form — `custom/app/views/super_admin/devise/sessions/new.html.erb`,
#      which decides whether to render the `otp_attempt` field at all
#
# They are not merely three readers of a config value; they have to agree. If
# (3) disagrees with (1), the operator is either asked for a code nothing
# checks, or — worse — refused for a code the form never offered a box for.
# Each of them used to inline the same
# `ActiveModel::Type::Boolean.new.cast(ENV.fetch('SUPER_ADMIN_ENFORCE_MFA', nil))`
# expression, so "keep the three identical" was a convention rather than
# something the code enforced. This is that expression, unchanged, in one
# place. See docs/fork/SUPER_ADMIN.md §4.3.
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
# `Custom` out of `Module.nesting`. See UPSTREAM_DIFF.md §2's namespace note.
class Custom::SuperAdminMfa
  # Same truthiness idiom as the sibling bootstrap flags
  # (`Custom::SuperAdminBootstrap#truthy?`): "true"/"1"/"t"/"on" are on;
  # unset, "false", "0", and anything unrecognised are off.
  #
  # Returns `nil` (not `false`) when the var is unset, exactly as the three
  # inlined copies did — every call site treats the result as a truthy test,
  # and coercing to a strict boolean here would be a behaviour change for no
  # gain.
  def self.enforced?
    ActiveModel::Type::Boolean.new.cast(ENV.fetch('SUPER_ADMIN_ENFORCE_MFA', nil))
  end
end
