# Fork overlay for GET /instagram/callback: without a verifiable `state`, don't
# start the flow at all.
#
# ## The bug this closes
#
# Upstream runs the full Instagram Login flow whatever `state` holds. With no
# `state` (or a forged or expired one), `account_id` is nil, and the flow fails:
# the code exchange is refused (or there is no code), and even the "user
# cancelled" branch needs an account to send the user back to. Every failure
# ends in `redirect_to_error_page`, which builds
# `app_new_instagram_inbox_url(account_id: nil)`. That route requires
# :account_id, so the URL helper raises ActionController::UrlGenerationError
# INSIDE the rescue handler, and the request escapes as a 500. Any bare hit on
# the public callback URL (a crawler, a copied link, Meta's own URL check, an
# expired state) produced one.
#
# ## What changes
#
# If `state` does not decode to an account id, redirect to /app, which sends a
# signed-in user to their dashboard and anyone else to login, and stop. As a
# side effect, an OAuth `code` that arrives with an unverifiable `state` is
# never exchanged for a token. The signed state is the flow's CSRF binding, so
# exchanging a code without it was never right.
#
# A valid state takes upstream's path unchanged (`super`).
#
# Why an overlay and not an edit: upstream's controller is byte-identical to
# ours and carries no `prepend_mod_with`, so it's prepended from
# config/initializers/custom_prepends.rb like the other overlays there.
# Spec: spec/custom/controllers/instagram/callbacks_controller_spec.rb.
module Custom::Instagram::CallbacksController
  def show
    return super if account_id.present?

    Rails.logger.warn('Instagram callback without a verifiable state; redirecting to /app')
    redirect_to '/app'
  end
end
