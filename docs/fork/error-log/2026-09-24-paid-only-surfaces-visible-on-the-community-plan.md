# Paid-only surfaces visible on the community plan after the v4.18.0 sync

- **Date**: 2026-09-24
- **Phase**: operations (post-sync rebuild)
- **Area**: frontend

## Symptom

The owner saw premium entries on the production inbox after the v4.18.0 sync
and rebuild, even though `INSTALLATION_NAME` was already "Zasmate" (the
custom-branded path hides feature-flag-gated entries). Found by reading the
code:

- **Calls** in the sidebar: `Sidebar.vue` `isCallsAvailable = isOnChatwootCloud || isEnterprise`,
  route meta `installationTypes: [CLOUD, ENTERPRISE]`, and no feature flag.
- **Settings → Security**: the parent route is gated on installation type only,
  and it renders a "SAML disabled" stub.
- Also keyed on `isEnterprise` alone: the SAML sign-in route, the Copilot panel,
  and the enterprise auto-assignment limit in inbox collaborators.

## Root cause

The image ships `enterprise/` because the fork's quota layer is built on it
(`custom/…/enterprise/api/v1/accounts_controller.rb`), so
`ChatwootApp.enterprise?` → the dashboard's `isEnterprise` is `'true'`. The
plan is `community` (no licence). Frontend checks that key on `isEnterprise`
alone treat that as a licensed enterprise install. The custom-branding switch
only covers entries that carry a feature flag.

## Fix

`custom/app/controllers/custom/dashboard_controller.rb`, prepended in
`config/initializers/custom_prepends.rb`: `app_config` reports
`IS_ENTERPRISE: false` when `ChatwootHub.pricing_plan == 'community'` and it's
not Chatwoot Cloud. The backend is untouched.

Rejected alternatives:
- **Enabling the features:** `enterprise/LICENSE` requires a paid licence for
  production use.
- **`DISABLE_ENTERPRISE=true`:** it switches off the enterprise backend,
  including the `limits` endpoint the fork's quota UI is served from.

The rule for every future sync and rebuild is `UPSTREAM_SYNC.md` §5b, linked
from `docs/fork/README.md` ground rule 6. Everything here lives in fork-only
files (ground rule 7), so an upstream sync can't conflict with it.

## Verification

```sh
docker compose -f docker-compose.yaml -f docker-compose.rspec.yaml run --rm test \
  sh -c "bundle install && bundle exec rails db:create db:schema:load && \
         bundle exec rspec spec/custom/controllers/dashboard_controller_spec.rb spec/custom/initializers"
# 24 examples, 0 failures
```

Proven: with `config.merge(IS_ENTERPRISE: false)` removed, the spec fails
(`reports IS_ENTERPRISE=false on the community plan`).

After deploy:
`curl -s https://inbox.zasmate.com/app/login | grep -o "isEnterprise: '[a-z]*'"` → `isEnterprise: 'false'`.

## Also found: dashboard request specs 500 in the rspec container

`GET /app/login` in a request spec returns 500 there, including upstream's own
`spec/controllers/dashboard_controller_spec.rb`. The page needs the Vite build,
and the container's build fails with
`app/javascript/dashboard/components/widgets/WootWriter/FullEditor.vue (11:2): … error during build`.
This isn't fixed here. The new spec tests `app_config` directly, and the
layout renders that value verbatim. Anyone who needs a rendered-page spec must
fix the container's frontend build first.
