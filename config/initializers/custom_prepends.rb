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
# reloading in development.
Rails.application.config.to_prepare do
  # Assignee picker: upstream builds the list inline instead of delegating to
  # Inbox#assignable_agents, so the model override alone does not cover it.
  Api::V1::Accounts::AssignableAgentsController.prepend(
    Custom::Api::V1::Accounts::AssignableAgentsController
  )

  # Super Admin password reset: stock Devise::PasswordsController auto-signs
  # in after a successful reset, bypassing the MFA-enforcing
  # SuperAdmin::Devise::SessionsController#create entirely. Guarded to the
  # :super_admin scope + SUPER_ADMIN_ENFORCE_MFA — see
  # custom/app/controllers/custom/devise_overrides/super_admin_passwords_guard.rb
  # and docs/fork/SUPER_ADMIN.md §4.3.
  Devise::PasswordsController.prepend(
    Custom::DeviseOverrides::SuperAdminPasswordsGuard
  )
end
