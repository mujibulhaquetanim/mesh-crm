# Fork overlay: AI integrations are never available to an account, so they drop
# out of Settings → Integrations. See Custom::VendorFeaturePolicy.
#
# `active?` is what AppsController#index filters the list on. Upstream's
# Integrations::App has no `prepend_mod_with`, so this is registered in
# config/initializers/custom_prepends.rb.
module Custom::Integrations::App
  def active?(account)
    return false if Custom::VendorFeaturePolicy.blocked_integration_app?(id)

    super
  end
end
