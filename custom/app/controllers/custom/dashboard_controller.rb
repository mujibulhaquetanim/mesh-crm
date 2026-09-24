# Fork overlay for the dashboard's boot config: on the community plan, tell the
# frontend this is NOT an enterprise install.
#
# ## The bug this closes
#
# The image ships upstream's `enterprise/` folder, and the fork's quota layer is
# built on it (custom/app/controllers/custom/enterprise/api/v1/accounts_controller.rb,
# docs/fork/ENTITLEMENTS.md), so `ChatwootApp.enterprise?` is true in production.
# The plan is `community`: no Chatwoot Enterprise licence, so no premium feature
# is usable. The frontend, though, decides visibility from `isEnterprise`
# alone in several places, and for a custom-branded instance a feature flag
# only hides what is behind a flag:
#
# - the **Calls** sidebar entry (`Sidebar.vue` `isCallsAvailable`, route meta
#   `installationTypes: [CLOUD, ENTERPRISE]`, no feature flag),
# - **Settings → Security** (parent route gated on installation type only; it
#   renders a "SAML disabled" stub),
# - the SAML sign-in route, the Copilot panel, the enterprise auto-assignment
#   limit, and every other `installationTypes: [..., ENTERPRISE]` route.
#
# Each upstream sync can add more (Calls arrived with the 2026-09-24 sync), so
# fixing them one component at a time would never finish.
#
# ## What changes
#
# `IS_ENTERPRISE` in the dashboard config is false when the installation's
# pricing plan is `community` (and this isn't Chatwoot Cloud). The frontend then
# takes its community-edition path everywhere, hiding enterprise-only surfaces.
# The backend is untouched: `ChatwootApp.enterprise?` stays true, so the quota
# endpoints and entitlement enforcement keep working.
#
# Why not `DISABLE_ENTERPRISE=true`: that turns the enterprise backend off too,
# including the `limits` endpoint the fork's quota UI is served from.
#
# Why not enable the features: `enterprise/LICENSE` allows production use only
# with a paid Chatwoot Enterprise licence. Hiding is the compliant option. If
# a licence is ever bought, set INSTALLATION_PRICING_PLAN and this overlay
# steps aside by itself.
#
# Registered in config/initializers/custom_prepends.rb (upstream's controller has
# no `prepend_mod_with`). Spec: spec/custom/controllers/dashboard_controller_spec.rb.
module Custom::DashboardController
  private

  def app_config
    config = super
    return config if ChatwootApp.chatwoot_cloud?
    return config unless ChatwootHub.pricing_plan == 'community'

    config.merge(IS_ENTERPRISE: false)
  end
end
