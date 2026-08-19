# Devise::PasswordsController is stock — it ships no `prepend_mod_with` hook
# of its own, so this overlay is wired in via config/initializers/custom_prepends.rb
# (the fork's documented mechanism for exactly this case), not via a
# `prepend_mod_with` call.
#
# `devise_for :super_admins` (config/routes.rb) is the ONLY `devise_for` in
# this app, so Devise::PasswordsController is only ever reached at
# /super_admin/password — but this module still guards on
# `resource_name == :super_admin` defensively, in case a future scope ever
# reuses the stock controller.
#
# The bug this closes: PUT/PATCH /super_admin/password (a completely
# separate Devise controller from SuperAdmin::Devise::SessionsController)
# calls `sign_in(resource_name, resource)` directly whenever
# `resource_class.sign_in_after_reset_password` is true (Devise's default —
# config/initializers/devise.rb:207 leaves it commented, i.e. unset/true).
# That `sign_in` call never passes through our MFA-enforcing
# `SuperAdmin::Devise::SessionsController#create` override at all, so with
# SUPER_ADMIN_ENFORCE_MFA on, a plain password reset — no OTP anywhere in
# the flow — could still mint a full super_admin session. See
# docs/fork/SUPER_ADMIN.md §4.3.
#
# Fix (fail-closed, smallest shape): when the flag is on for this scope, the
# password reset itself still completes normally (host access / "reset your
# password" remains the documented recovery path — see §4.0), but the two
# calls Devise's own #update action makes when it *would* have signed the
# resource in are turned into what Devise itself already does when
# `sign_in_after_reset_password` is configured off: no session is minted,
# and the operator lands back on the sign-in page instead of the dashboard.
# We only intercept those two calls (not the whole #update action), so the
# rest of Devise's password-reset logic — token validation, saving the new
# password, flash messages, error handling — is entirely untouched.
#
# Inert by default: with the flag off (or any other scope), both overrides
# are a straight `super`, so behaviour is byte-identical to upstream.
module Custom::DeviseOverrides::SuperAdminPasswordsGuard
  def sign_in(*args)
    return super unless super_admin_mfa_reset_guard?

    # Deliberately not calling super — the whole point is that this request
    # must not mint a session. No warden/current_super_admin state changes.
    false
  end

  private

  # Devise's own `after_resetting_password_path_for` is a protected internal
  # hook — `Devise::PasswordsController#update` is its only caller, and it
  # calls it on `self`. Declaring the override public would have widened that
  # to callable-from-outside surface on every controller in the app that
  # inherits from Devise's, for nothing: `super` still reaches upstream's
  # definition from here, and self-calls ignore visibility.
  def after_resetting_password_path_for(resource)
    return super unless super_admin_mfa_reset_guard?

    new_session_path(resource_name)
  end

  # Flag read via Custom::SuperAdminMfa.enforced? — the single reader shared
  # with the sign-in enforcement and the sign-in form, so the three surfaces
  # cannot drift apart on what "enforcement is on" means.
  def super_admin_mfa_reset_guard?
    resource_name == :super_admin && Custom::SuperAdminMfa.enforced?
  end
end
