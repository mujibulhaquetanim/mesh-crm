#!/usr/bin/env python3
"""Fork policy check: brand + vendor feature policy. Run before every push and rebuild.

    python3 scripts/fork-policy/check.py                  # the checkout this script is in
    python3 scripts/fork-policy/check.py --tree DIR       # another checkout (the fresh build clone)
    python3 scripts/fork-policy/check.py --live https://inbox.zasmate.com   # the running inbox

TREE mode reads source files only (no Ruby, no Docker) and fails when:
  brand.*   a vendor-visible English string, the PWA manifest, the logo artwork
            or the page-title template says "Chatwoot" instead of the brand;
  mit.*     production is MIT-only: the fork quota endpoint and its route, the
            build's enterprise/ strip and image check, and no fork Ruby that
            references enterprise/ (docs/fork/MIT_ONLY.md);
  policy.*  a piece of the vendor feature policy is missing: the policy list,
            an overlay, its registration, or the upstream extension point the
            overlay hangs on (an upstream sync can drop one and the overlay
            then silently stops loading);
  repo.*    a conflict marker is committed.
It WARNS when upstream adds an integration app this policy has not classified,
because a new app can be a new AI reply path (docs/fork/VENDOR_FEATURE_POLICY.md).

LIVE mode fetches the running inbox and fails when the page title, the
branding rows (INSTALLATION_NAME, BRAND_NAME, the brand/legal URLs), the
manifest or the served logos still say Chatwoot, or when IS_ENTERPRISE is on.
Those rows live in the database, so only LIVE mode can see them; a rebuild
does not change them (docs/fork/REBRAND_PRODUCTION.md).

Prints check ids and verdicts, never secrets. Exit 1 on any FAIL.
READ THE RESULT LINE, not just the exit code.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

WORD = re.compile(r'\bChatwoot\b')

LOCALE_FILES = [
    'app/javascript/dashboard/i18n/locale/en/*.json',
    'app/javascript/widget/i18n/locale/en.json',
    'app/javascript/survey/i18n/locale/en.json',
]
BRAND_ASSETS = ['logo.svg', 'logo_dark.svg', 'logo_thumbnail.svg']

# Every integration app upstream ships, classified. BLOCKED must equal
# Custom::VendorFeaturePolicy::BLOCKED_INTEGRATION_APPS; the check enforces it.
BLOCKED_APPS = {'openai', 'dialogflow'}
ALLOWED_APPS = {'webhooks', 'dashboard_apps', 'linear', 'notion', 'slack',
                'google_translate', 'dyte', 'shopify', 'leadsquared'}

# (check id, file, regex that must match, what it means when it does not)
POLICY_REQUIREMENTS = [
    ('policy.list', 'custom/app/services/custom/vendor_feature_policy.rb',
     r"BLOCKED_INTEGRATION_APPS\s*=\s*%w\[([^\]]*)\]", 'the policy list is gone'),
    ('policy.guard', 'custom/app/controllers/custom/concerns/vendor_feature_guard.rb',
     r'def refuse_platform_managed_feature', 'the 403 responder is gone'),
    ('policy.agent_bots', 'custom/app/controllers/custom/api/v1/accounts/agent_bots_controller.rb',
     r'before_action :refuse_agent_bots_to_vendors\s*$', 'agent bots are no longer refused on EVERY action'),
    ('policy.inbox_bot', 'custom/app/controllers/custom/api/v1/accounts/inboxes_controller.rb',
     r'before_action :refuse_inbox_agent_bot_to_vendors, only: \[:agent_bot, :set_agent_bot\]',
     'the inbox bot setting is no longer refused'),
    ('policy.hooks', 'custom/app/controllers/custom/api/v1/accounts/integrations/hooks_controller.rb',
     r'before_action :refuse_blocked_integration_to_vendors, only: \[:create, :update, :process_event\]',
     'AI integration hooks are no longer refused'),
    ('policy.hook_disabled', 'custom/app/models/custom/integrations/hook.rb',
     r'def disabled\?', 'existing Dialogflow hooks would fire again'),
    ('policy.app_hidden', 'custom/app/models/custom/integrations/app.rb',
     r'def active\?\(account\)', 'AI integrations would show in the list again'),
    ('policy.app_registered', 'config/initializers/custom_prepends.rb',
     r'Integrations::App,\s*Custom::Integrations::App', 'the integrations-list overlay is not registered'),
    ('policy.enterprise_hidden', 'custom/app/controllers/custom/dashboard_controller.rb',
     r'IS_ENTERPRISE: false', 'paid-only surfaces would show on the community plan'),
    ('policy.enterprise_registered', 'config/initializers/custom_prepends.rb',
     r'DashboardController,\s*Custom::DashboardController', 'the dashboard overlay is not registered'),
    # MIT-only production (docs/fork/MIT_ONLY.md): the quota endpoint is fork
    # code on the MIT core, and the build strips enterprise/.
    ('mit.limits_controller', 'custom/app/controllers/custom/account_limits_controller.rb',
     r'class Custom::AccountLimitsController < Api::V1::Accounts::BaseController',
     'the fork quota endpoint is gone — the dashboard quota UI would 404 without enterprise/'),
    ('mit.limits_route', 'config/initializers/custom_routes.rb',
     r"to: 'custom/account_limits#show'", 'the quota route no longer points at the fork controller'),
    ('mit.build_strips_enterprise', 'scripts/build-ce-image.sh',
     r'rm -rf "\$WORK/enterprise"', 'the build no longer strips enterprise/ — licensed code would ship'),
    ('mit.build_verifies_image', 'scripts/build-ce-image.sh',
     r'/app/enterprise', 'the build no longer proves the image has no enterprise/'),
    ('policy.spec', 'spec/custom/controllers/api/v1/accounts/vendor_feature_policy_spec.rb',
     r"feature_managed_by_platform", 'the policy spec is gone'),
    # The upstream extension points the overlays above load through.
    ('policy.hook_point', 'app/controllers/api/v1/accounts/agent_bots_controller.rb',
     r"prepend_mod_with\('Api::V1::Accounts::AgentBotsController'\)", 'upstream dropped the extension point'),
    ('policy.hook_point', 'app/controllers/api/v1/accounts/inboxes_controller.rb',
     r"prepend_mod_with\('Api::V1::Accounts::InboxesController'\)", 'upstream dropped the extension point'),
    ('policy.hook_point', 'app/controllers/api/v1/accounts/integrations/hooks_controller.rb',
     r"prepend_mod_with\('Api::V1::Accounts::Integrations::HooksController'\)", 'upstream dropped the extension point'),
    ('policy.hook_point', 'app/models/integrations/hook.rb',
     r"prepend_mod_with\('Integrations::Hook'\)", 'upstream dropped the extension point'),
]


class Report:
    def __init__(self):
        self.fails, self.warns, self.passed = [], [], 0

    def check(self, check_id, ok, message):
        if ok:
            self.passed += 1
        else:
            self.fails.append(f'{check_id}: {message}')

    def warn(self, check_id, message):
        self.warns.append(f'{check_id}: {message}')

    def finish(self, subject):
        print(f'fork policy check — {subject}\n')
        for f in self.fails:
            print('  FAIL ', f)
        for w in self.warns:
            print('  warn ', w)
        print(f'\n{self.passed} passed, {len(self.fails)} failed, {len(self.warns)} warnings')
        print('RESULT:', 'NOT SAFE TO SHIP' if self.fails else 'ok to ship')
        return 1 if self.fails else 0


def string_leaves(node, path=''):
    if isinstance(node, dict):
        for key, value in node.items():
            yield from string_leaves(value, f'{path}.{key}' if path else key)
    elif isinstance(node, list):
        for i, value in enumerate(node):
            yield from string_leaves(value, f'{path}[{i}]')
    elif isinstance(node, str):
        yield path, node


def check_tree(root, brand, report):
    # brand.locale — values only: keys, interpolation variables and identifiers
    # such as {latestChatwootVersion} are code, not copy.
    locale_files = [p for pattern in LOCALE_FILES for p in sorted(root.glob(pattern))]
    report.check('brand.locale_files', bool(locale_files), 'no English locale files found — wrong --tree?')
    for path in locale_files:
        try:
            data = json.loads(path.read_text(encoding='utf-8'))
        except ValueError as e:
            report.check('brand.locale', False, f'{path.relative_to(root)} is not valid JSON ({e})')
            continue
        hits = [key for key, value in string_leaves(data) if WORD.search(value)]
        report.check('brand.locale', not hits,
                     f'{path.relative_to(root)}: "Chatwoot" in {", ".join(hits[:5])}'
                     + (f' (+{len(hits) - 5} more)' if len(hits) > 5 else ''))

    # brand.backend_locale — config/locales/en.yml values (no YAML parser in the
    # stdlib: a value is whatever follows `key:` on the line).
    en_yml = root / 'config/locales/en.yml'
    if en_yml.exists():
        hits = [n for n, line in enumerate(en_yml.read_text(encoding='utf-8').splitlines(), 1)
                if ':' in line and not line.lstrip().startswith('#') and WORD.search(line.split(':', 1)[1])]
        report.check('brand.backend_locale', not hits, f'config/locales/en.yml: "Chatwoot" on line(s) {hits[:10]}')

    manifest = root / 'public/manifest.json'
    try:
        m = json.loads(manifest.read_text(encoding='utf-8'))
        report.check('brand.manifest', m.get('name') == brand and m.get('short_name') == brand,
                     f'public/manifest.json name/short_name are {m.get("name")!r}/{m.get("short_name")!r}, not {brand!r}'
                     ' (the installed-app window title)')
    except (OSError, ValueError) as e:
        report.check('brand.manifest', False, f'public/manifest.json unreadable ({e})')

    for name in BRAND_ASSETS:
        path = root / 'public/brand-assets' / name
        report.check('brand.assets', path.exists() and 'chatwoot' not in path.read_text(errors='ignore').lower(),
                     f'public/brand-assets/{name} is missing or still carries the Chatwoot artwork')

    layout = root / 'app/views/layouts/vueapp.html.erb'
    if layout.exists():
        title = re.search(r'<title>(.*?)</title>', layout.read_text(encoding='utf-8'), re.S)
        report.check('brand.title_template', bool(title) and 'INSTALLATION_NAME' in title.group(1)
                     and not WORD.search(title.group(1)),
                     'vueapp.html.erb <title> no longer comes from INSTALLATION_NAME (the browser tab title)')

    for check_id, rel, pattern, meaning in POLICY_REQUIREMENTS:
        path = root / rel
        text = path.read_text(encoding='utf-8') if path.exists() else ''
        match = re.search(pattern, text, re.M)
        report.check(check_id, bool(match), f'{rel}: {meaning}')
        if check_id == 'policy.list' and match:
            listed = set(match.group(1).split())
            report.check('policy.list_matches', listed == BLOCKED_APPS,
                         f'the Ruby list {sorted(listed)} differs from this checker\'s {sorted(BLOCKED_APPS)} — update both')

    # mit.no_enterprise_dependency — fork Ruby must not reach into enterprise/:
    # production has no such folder, so a reference is a boot or runtime error
    # there (docs/fork/MIT_ONLY.md). Comments are ignored.
    offenders = []
    for path in sorted((root / 'custom').rglob('*.rb')):
        for n, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
            code = line.split('#', 1)[0]
            if re.search(r'\bEnterprise::|Custom::Enterprise\b', code):
                offenders.append(f'{path.relative_to(root)}:{n}')
    report.check('mit.no_enterprise_dependency', not offenders,
                 'fork code references enterprise/: ' + ', '.join(offenders[:5]))

    apps_yml = root / 'config/integration/apps.yml'
    if apps_yml.exists():
        apps = set(re.findall(r'^([a-z_]+):\s*$', apps_yml.read_text(encoding='utf-8'), re.M))
        for app in sorted(apps - BLOCKED_APPS - ALLOWED_APPS):
            report.warn('policy.new_integration',
                        f'upstream added integration app {app!r}: decide whether it is an AI reply path, '
                        'then add it to BLOCKED (policy + checker) or ALLOWED (checker)')

    if (root / '.git').exists():
        # Markdown is excluded: the sync runbooks quote conflict blocks as examples.
        out = subprocess.run(['git', '-C', str(root), 'grep', '-lE', '^(<<<<<<< |>>>>>>> )', '--', '.', ':!*.md'],
                             capture_output=True, text=True)
        report.check('repo.conflict_markers', not out.stdout.strip(),
                     'conflict markers committed in: ' + ', '.join(out.stdout.split()[:5]))


def fetch(url):
    request = urllib.request.Request(url, headers={'User-Agent': 'fork-policy-check'})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode('utf-8', errors='replace')


def check_live(base, brand, report):
    base = base.rstrip('/')
    try:
        page = fetch(f'{base}/app/login')
    except (urllib.error.URLError, OSError) as e:
        report.check('live.reachable', False, f'{base}/app/login did not answer ({e})')
        return

    title = re.search(r'<title>(.*?)</title>', page, re.S)
    title = ' '.join(title.group(1).split()) if title else None
    report.check('live.title', title == brand, f'browser tab title is {title!r}, not {brand!r}')

    description = re.search(r'<meta name="description" content="([^"]*)"', page)
    report.check('live.description', not (description and WORD.search(description.group(1))),
                 'the page description says Chatwoot (it follows INSTALLATION_NAME)')

    config = re.search(r'window\.globalConfig\s*=\s*(\{.*?\})\s*\n', page, re.S)
    try:
        config = json.loads(config.group(1)) if config else None
    except ValueError:
        config = None
    report.check('live.global_config', config is not None, 'window.globalConfig not found on the page')
    if config:
        for key in ('INSTALLATION_NAME', 'BRAND_NAME'):
            report.check(f'live.{key}', config.get(key) == brand,
                         f'{key} row is {config.get(key)!r}, not {brand!r} (database row: see REBRAND_PRODUCTION.md)')
        for key in ('BRAND_URL', 'WIDGET_BRAND_URL', 'TERMS_URL', 'PRIVACY_URL'):
            value = config.get(key) or ''
            report.check(f'live.{key}', 'chatwoot' not in value.lower(), f'{key} row still points at {value!r}')
        report.check('live.IS_ENTERPRISE', config.get('IS_ENTERPRISE') is False,
                     f'IS_ENTERPRISE is {config.get("IS_ENTERPRISE")!r}: paid-only surfaces are showing')
        print(f'serving GIT_SHA {config.get("GIT_SHA")}, version {config.get("APP_VERSION")}')

    try:
        m = json.loads(fetch(f'{base}/manifest.json'))
        report.check('live.manifest', m.get('name') == brand and m.get('short_name') == brand,
                     f'manifest name/short_name are {m.get("name")!r}/{m.get("short_name")!r}')
    except (urllib.error.URLError, OSError, ValueError) as e:
        report.check('live.manifest', False, f'manifest.json unreadable ({e})')

    for name in BRAND_ASSETS:
        try:
            svg = fetch(f'{base}/brand-assets/{name}')
            report.check('live.assets', 'chatwoot' not in svg.lower(), f'/brand-assets/{name} serves the Chatwoot artwork')
        except (urllib.error.URLError, OSError) as e:
            report.check('live.assets', False, f'/brand-assets/{name} unreadable ({e})')


def main():
    parser = argparse.ArgumentParser(description='Fork policy check: brand + vendor feature policy.')
    parser.add_argument('--tree', default=str(Path(__file__).resolve().parents[2]),
                        help='checkout to check (default: the one this script is in)')
    parser.add_argument('--live', metavar='URL', help='check the running inbox at URL instead of a checkout')
    parser.add_argument('--brand', default='Zasmate', help='the product name every surface must show')
    args = parser.parse_args()

    report = Report()
    if args.live:
        check_live(args.live, args.brand, report)
        return report.finish(f'live {args.live}, brand {args.brand!r}')
    root = Path(args.tree).resolve()
    check_tree(root, args.brand, report)
    return report.finish(f'tree {root}, brand {args.brand!r}')


if __name__ == '__main__':
    sys.exit(main())
