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
  #
  # ⚠ As of the 2026-09-14 upstream sync this entry no longer does the work:
  # upstream added its own `prepend_mod_with` to that controller, which prepends
  # this same module by name first. `PrependOnce` matches by name, so this call
  # now always returns false. Kept on purpose — the overlay is a security control
  # (it hides the platform service admin from the picker), and this is the
  # fallback if upstream drops the hook again. Do not "clean it up" without
  # re-checking that upstream still ships the hook.
  Custom::PrependOnce.call(
    Api::V1::Accounts::AssignableAgentsController,
    Custom::Api::V1::Accounts::AssignableAgentsController
  )

  # WhatsApp webhook signature: upstream only REQUIRES `X-Hub-Signature-256`
  # when the channel itself carries an app secret (or came from embedded
  # signup), which leaves the manual-source whatsapp_cloud inboxes this
  # platform provisions accepting unsigned POSTs. The overlay requires a
  # signature whenever the installation has a secret to verify with. See
  # custom/app/controllers/custom/webhooks/whatsapp_controller.rb.
  # (Reloadable target; the guard is a no-op here, same as the entry above.)
  Custom::PrependOnce.call(
    Webhooks::WhatsappController,
    Custom::Webhooks::WhatsappController
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

  # Messenger webhook subscription handshake (GET /bot): the token Meta sends
  # must equal FB_VERIFY_TOKEN (constant-time; unset rejects everything). See
  # custom/app/services/custom/facebook_messenger_verify_token.rb.
  #
  # Non-reloadable target: ChatwootFbProvider is defined inside
  # config/initializers/facebook_messenger.rb, not autoloaded.
  Custom::PrependOnce.call(
    ChatwootFbProvider,
    Custom::FacebookMessengerVerifyToken
  )

  # Instagram Login callback (GET /instagram/callback): without a verifiable
  # `state`, redirect to /app instead of running the flow. Upstream's error path
  # needs an account id to build its URL and 500s without one. See
  # custom/app/controllers/custom/instagram/callbacks_controller.rb.
  Custom::PrependOnce.call(
    Instagram::CallbacksController,
    Custom::Instagram::CallbacksController
  )
end
