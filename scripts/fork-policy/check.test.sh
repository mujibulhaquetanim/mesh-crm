#!/usr/bin/env bash
#
# Self-test for scripts/fork-policy/check.py: every rule must FAIL when broken.
#
#   Usage: scripts/fork-policy/check.test.sh
#
# Copies the files the checker reads into a scratch tree, confirms the clean
# copy passes, then breaks one rule at a time and expects that rule's FAIL.
# Live mode is tested against a local http.server serving fixture pages.
#
# READ THE SUMMARY LINE, not just the exit code.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECK="$SCRIPT_DIR/check.py"
WORK="$(mktemp -d)"
SERVER_PID=""
trap '[ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT
PASSED=0
FAILED=0

# Every path check.py reads in tree mode.
PATHS=(
  app/javascript/dashboard/i18n/locale/en
  app/javascript/widget/i18n/locale/en.json
  app/javascript/survey/i18n/locale/en.json
  config/locales/en.yml
  config/integration/apps.yml
  config/initializers/custom_prepends.rb
  public/manifest.json
  public/brand-assets
  app/views/layouts/vueapp.html.erb
  app/controllers/api/v1/accounts/agent_bots_controller.rb
  app/controllers/api/v1/accounts/inboxes_controller.rb
  app/controllers/api/v1/accounts/integrations/hooks_controller.rb
  app/models/integrations/hook.rb
  custom
  spec/custom/controllers/api/v1/accounts/vendor_feature_policy_spec.rb
  config/initializers/custom_routes.rb
  scripts/build-ce-image.sh
  app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue
  app/javascript/dashboard/fork/callChannels.js
  app/models/account.rb
  scripts/fork-policy/core-moves.reviewed
)

fresh_tree() {
  rm -rf "$WORK/tree" && mkdir -p "$WORK/tree"
  (cd "$ROOT" && cp -r --parents "${PATHS[@]}" "$WORK/tree/")
}

run_tree() { CASE="$1"; OUT="$(python3 "$CHECK" --tree "$WORK/tree" 2>&1)"; }

expect_fail() {
  if printf '%s\n' "$OUT" | grep -E "FAIL +$1" >/dev/null; then PASSED=$((PASSED+1))
  else FAILED=$((FAILED+1)); echo "FAIL: $CASE — expected a FAIL for $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi
}
expect_warn() {
  if printf '%s\n' "$OUT" | grep -E "warn +$1" >/dev/null; then PASSED=$((PASSED+1))
  else FAILED=$((FAILED+1)); echo "FAIL: $CASE — expected a warn for $1"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi
}
expect_ok() {
  if printf '%s\n' "$OUT" | grep -q "RESULT: ok to ship"; then PASSED=$((PASSED+1))
  else FAILED=$((FAILED+1)); echo "FAIL: $CASE — expected ok to ship"; printf '%s\n' "$OUT" | sed 's/^/      | /'; fi
}

# break <file> <perl substitution> — edit one file in the scratch tree.
break_file() { perl -0pi -e "$2" "$WORK/tree/$1"; }

# The clean copy also proves identifiers are not copy: generalSettings.json
# carries the key UPDATE_CHATWOOT and the variable {latestChatwootVersion}.
fresh_tree; run_tree 'clean copy'; expect_ok

fresh_tree; break_file app/javascript/dashboard/i18n/locale/en/inboxMgmt.json 's/not a problem with Zasmate/not a problem with Chatwoot/'
run_tree 'Chatwoot back in a locale value'; expect_fail 'brand.locale'

fresh_tree; break_file public/manifest.json 's/"name": "Zasmate"/"name": "Chatwoot"/'
run_tree 'manifest renamed'; expect_fail 'brand.manifest'

fresh_tree; echo '<svg><text>chatwoot</text></svg>' > "$WORK/tree/public/brand-assets/logo.svg"
run_tree 'Chatwoot artwork restored'; expect_fail 'brand.assets'

fresh_tree; break_file app/views/layouts/vueapp.html.erb 's/<title>.*?<\/title>/<title>Chatwoot<\/title>/s'
run_tree 'title hardcoded'; expect_fail 'brand.title_template'

fresh_tree; break_file custom/app/controllers/custom/api/v1/accounts/agent_bots_controller.rb 's/before_action :refuse_agent_bots_to_vendors$/before_action :refuse_agent_bots_to_vendors, only: [:create]/m'
run_tree 'agent bots refused only on create'; expect_fail 'policy.agent_bots'

fresh_tree; rm "$WORK/tree/custom/app/controllers/custom/api/v1/accounts/inboxes_controller.rb"
run_tree 'inbox overlay deleted'; expect_fail 'policy.inbox_bot'

fresh_tree; break_file custom/app/services/custom/vendor_feature_policy.rb 's/%w\[openai dialogflow\]/%w[openai]/'
run_tree 'Dialogflow dropped from the policy list'; expect_fail 'policy.list_matches'

fresh_tree; break_file config/initializers/custom_prepends.rb 's/Integrations::App,\s*Custom::Integrations::App/X/'
run_tree 'app overlay unregistered'; expect_fail 'policy.app_registered'

fresh_tree; break_file app/controllers/api/v1/accounts/inboxes_controller.rb "s/^.*prepend_mod_with.*\$//m"
run_tree 'upstream dropped an extension point'; expect_fail 'policy.hook_point'

fresh_tree; rm "$WORK/tree/custom/app/controllers/custom/account_limits_controller.rb"
run_tree 'fork quota endpoint deleted'; expect_fail 'mit.limits_controller'

fresh_tree; break_file scripts/build-ce-image.sh 's/rm -rf "\$WORK\/enterprise"/true/'
run_tree 'build stops stripping enterprise/'; expect_fail 'mit.build_strips_enterprise'

fresh_tree; break_file app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue 's/return withoutUnservedCallChannels\(channels, \{.*?\}\);/return channels;/s'
run_tree 'sync took upstream ChannelList.vue'; expect_fail 'policy.call_tiles_hidden'

fresh_tree; break_file custom/app/models/custom/account.rb 's/Custom::Account\.calls_served\? && super/super/'
run_tree 'channel_voice honoured on a build without calls'; expect_fail 'policy.voice_flag_served'

fresh_tree; break_file scripts/build-ce-image.sh 's/--require-synced//'
run_tree 'build stops requiring an upstream sync'; expect_fail 'mit.build_gates_core_moves'

fresh_tree; printf 'module Custom::Foo\n  def bar = Enterprise::Something.call\nend\n' > "$WORK/tree/custom/app/services/custom/foo.rb"
run_tree 'fork code reaches into enterprise/'; expect_fail 'mit.no_enterprise_dependency'

fresh_tree; printf '# mentions Enterprise::Something only in a comment\n' > "$WORK/tree/custom/app/services/custom/foo.rb"
run_tree 'a comment is not a dependency'; expect_ok

fresh_tree; printf 'captain_voice:\n  id: captain_voice\n' >> "$WORK/tree/config/integration/apps.yml"
run_tree 'upstream adds an unclassified app'; expect_warn 'policy.new_integration'

# ── live mode, against fixture pages ──────────────────────────────────────────
serve() {  # serve <INSTALLATION_NAME> <TERMS_URL> <title>
  rm -rf "$WORK/site" && mkdir -p "$WORK/site/app" "$WORK/site/brand-assets"
  cat > "$WORK/site/app/login" <<EOF
<html><head><title>
  $3
</title>
<meta name="description" content="$1 is a customer support solution">
<script>
      window.globalConfig = {"INSTALLATION_NAME":"$1","BRAND_NAME":"$1","BRAND_URL":"https://zasmate.com","WIDGET_BRAND_URL":"https://zasmate.com","TERMS_URL":"$2","PRIVACY_URL":"https://zasmate.com/legal/privacy","IS_ENTERPRISE":false,"GIT_SHA":"abc","APP_VERSION":"4.18.0"}
      window.browserConfig = {}
</script></head></html>
EOF
  echo '{"name":"Zasmate","short_name":"Zasmate"}' > "$WORK/site/manifest.json"
  for f in logo.svg logo_dark.svg logo_thumbnail.svg; do echo '<svg><text>Zasmate</text></svg>' > "$WORK/site/brand-assets/$f"; done
}
run_live() { CASE="$1"; OUT="$(python3 "$CHECK" --live "http://127.0.0.1:$PORT" 2>&1)"; }

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
mkdir -p "$WORK/site"
(cd "$WORK/site" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1) &
SERVER_PID=$!
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/" >/dev/null && break; sleep 0.1; done

serve Zasmate https://zasmate.com/legal/terms Zasmate
run_live 'branded inbox'; expect_ok

serve Chatwoot https://www.chatwoot.com/terms-of-service Chatwoot
run_live 'unbranded rows (production on 2026-09-27)'
expect_fail 'live.title'; expect_fail 'live.INSTALLATION_NAME'; expect_fail 'live.TERMS_URL'; expect_fail 'live.description'

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
