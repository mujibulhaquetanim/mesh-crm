# Fork: prepend Custom:: overlays onto upstream classes that ship NO
# `prepend_mod_with` hook of their own.
#
# Most of the fork's Ruby customization needs nothing here — upstream calls
# `Klass.prepend_mod_with('Klass')` at the bottom of the file it wants to be
# extensible, and that resolves `Custom::` modules by name automatically. This
# file exists only for the classes that upstream did not make extensible, so the
# overlay still requires zero edits to core files and an upstream pull merges
# clean.
#
# `to_prepare` (not a bare constant reference) so the prepend survives Zeitwerk
# reloading in development — and `Custom::PrependOnce` (not a bare `prepend`)
# so that reloading does not STACK the overlay on a target the reloader keeps.
# `Devise::PasswordsController` below is exactly that case: it comes from a gem
# and is loaded once, while the overlay prepended onto it is rebuilt on every
# reload. See custom/app/services/custom/prepend_once.rb for the full reasoning.
Rails.application.config.to_prepare do
  # Assignee picker: upstream builds the list inline instead of delegating to
  # Inbox#assignable_agents, so the model override alone does not cover it.
  # (Reloadable target — the guard is a no-op here, but it costs nothing and
  # keeps one shape for both entries.)
  Custom::PrependOnce.call(
    Api::V1::Accounts::AssignableAgentsController,
    Custom::Api::V1::Accounts::AssignableAgentsController
  )

  # Super Admin password reset: stock Devise::PasswordsController auto-signs
  # in after a successful reset, bypassing the MFA-enforcing
  # SuperAdmin::Devise::SessionsController#create entirely. Guarded to the
  # :super_admin scope + SUPER_ADMIN_ENFORCE_MFA — see
  # custom/app/controllers/custom/devise_overrides/super_admin_passwords_guard.rb
  # and docs/fork/SUPER_ADMIN.md §4.3.
  #
  # Gem-owned, non-reloadable target — the one the guard actually exists for.
  Custom::PrependOnce.call(
    Devise::PasswordsController,
    Custom::DeviseOverrides::SuperAdminPasswordsGuard
  )
end
