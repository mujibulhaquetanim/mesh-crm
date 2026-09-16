#!/usr/bin/env python3
"""Turn a mesh-crm .env into a production one, ready to ship to the VPS.

Prints a summary. NEVER prints a value — the output is safe to paste anywhere.

  python3 scripts/make-prod-env.py .env \
      --db 'postgresql://…/mesh-inbox?sslmode=verify-full' \
      --frontend https://inbox.zasmate.com \
      --dashboard-url https://zasmate.com \
      --r2-endpoint https://<ACCOUNT_ID>.r2.cloudflarestorage.com \
      --r2-key <ACCESS_KEY_ID> --r2-secret <SECRET> --r2-bucket mesh-inbox

Back up first (`cp .env .env.bak.localdev` — note `.env.bak*` is the gitignored
shape; `.env.localdev.bak` is NOT ignored) and restore afterwards, or every later
local command in this repo silently talks to production.
"""
import argparse, re, secrets, string, sys

ap = argparse.ArgumentParser()
ap.add_argument('envfile')
ap.add_argument('--db', required=True, help='CRM_DATABASE_URL — the mesh-inbox project')
ap.add_argument('--frontend', required=True, help='CRM_FRONTEND_URL — public https origin')
ap.add_argument('--r2-endpoint'); ap.add_argument('--r2-key')
ap.add_argument('--r2-secret');   ap.add_argument('--r2-bucket')
ap.add_argument('--dashboard-url', default='',
                help='public dashboard ORIGIN, e.g. https://zasmate.com. Sets EXTERNAL_LOGIN_URL, '
                     'which is where an unauthenticated visitor to the inbox is bounced. Omit it '
                     'and the dev value is carried through — see troubleshooting/425')
ap.add_argument('--storage-local', action='store_true',
                help='fall back to on-volume storage instead of R2 (see the warning it prints)')
a = ap.parse_args()

alnum = lambda n: ''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))
NEW = {
    # The four the boot guard checks. Regenerated every run — never reuse a dev value.
    'SECRET_KEY_BASE': secrets.token_hex(64),
    'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY': alnum(32),
    'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY': alnum(32),
    'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT': alnum(32),
    'CRM_DATABASE_URL': a.db,
    'CRM_FRONTEND_URL': a.frontend,
}
# ⚠ OWNED, not carried, since troubleshooting/425. This key drives
# window.location.replace() for every unauthenticated visitor to the inbox, and
# with ENABLE_SSO_ONLY_LOGIN=true it is the ONLY way in. Carried through from a
# dev env it sent every tenant to a domain that no longer exists, while every
# health check stayed green.
#
# ⚠ Setting it here is NOT sufficient on an already-seeded installation:
# GlobalConfigService reads the `installation_configs` TABLE, which is seeded
# from this env at db:chatwoot_prepare time. On an existing install you must also
# update the row. The check in check-prod-env.py catches the env half.
if a.dashboard_url:
    NEW['EXTERNAL_LOGIN_URL'] = a.dashboard_url.rstrip('/') + '/login'
r2 = [a.r2_endpoint, a.r2_key, a.r2_secret, a.r2_bucket]
if a.storage_local:
    NEW['CRM_ACTIVE_STORAGE_SERVICE'] = 'local'
elif all(r2):
    NEW.update({
        'CRM_ACTIVE_STORAGE_SERVICE': 's3_compatible',
        'STORAGE_ENDPOINT': a.r2_endpoint,
        'STORAGE_ACCESS_KEY_ID': a.r2_key,
        'STORAGE_SECRET_ACCESS_KEY': a.r2_secret,
        'STORAGE_BUCKET_NAME': a.r2_bucket,
        'STORAGE_REGION': 'auto',            # R2 has no regions
        'STORAGE_FORCE_PATH_STYLE': 'true',  # required against a custom endpoint
    })
elif any(r2):
    sys.exit('error: pass ALL of --r2-endpoint/--r2-key/--r2-secret/--r2-bucket, or none')
else:
    sys.exit('error: give the R2 flags, or --storage-local. Left unset, '
             'CRM_ACTIVE_STORAGE_SERVICE defaults to s3_compatible with BLANK '
             'credentials (config/storage.yml uses ENV.fetch(..., "")), so Rails '
             'boots healthy and the first attachment upload fails.')

# compose's `environment:` block sets these and BEATS env_file, so a copy here is
# dead weight that misleads the next reader. FRONTEND_URL is derived from
# CRM_FRONTEND_URL by compose, so it belongs in this list too.
COMPOSE_OWNS = ['FRONTEND_URL', 'RAILS_ENV', 'RAILS_LOG_TO_STDOUT', 'REDIS_URL',
                'ACTIVE_STORAGE_SERVICE', 'POSTGRES_HOST', 'POSTGRES_PORT',
                'POSTGRES_DATABASE', 'POSTGRES_USERNAME', 'POSTGRES_PASSWORD',
                'POSTGRES_SSLMODE']

out, seen, disabled = [], set(), []
for line in open(a.envfile):
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=', line)
    k = m.group(1) if m and not line.lstrip().startswith('#') else None
    if k in COMPOSE_OWNS:
        out.append(f"# [prod] compose sets {k}; removed so this file cannot disagree with it\n")
        disabled.append(k); continue
    if k in NEW:
        out.append(f"{k}={NEW[k]}\n"); seen.add(k); continue
    out.append(line)

missing = [k for k in NEW if k not in seen]
if missing:
    out.append("\n# --- added for production (docker-compose.prod.yaml / storage.yml read these) ---\n")
    out.extend(f"{k}={NEW[k]}\n" for k in missing)

open(a.envfile, 'w').writelines(out)
print(f"rewrote {a.envfile}")
print("  regenerated : SECRET_KEY_BASE + 3 ACTIVE_RECORD_ENCRYPTION_* (fresh, distinct)")
print(f"  storage     : {NEW['CRM_ACTIVE_STORAGE_SERVICE']}")
print(f"  appended    : {', '.join(sorted(missing)) or '(none)'}")
print(f"  removed     : {len(disabled)} compose-owned -> {', '.join(disabled)}")
if a.storage_local:
    print("\n  ⚠ storage=local. Attachments go to the prod_storage volume — they DO survive\n"
          "    redeploys, but they are on ONE box with no backup and no replication, and\n"
          "    migrating to R2 later means updating active_storage_blobs.service_name for\n"
          "    every row. s3_compatible -> R2 is a same-service-name swap with no DB change.")
print("\n  NEXT: escrow the four secrets, then")
print(f"        python3 scripts/check-prod-env.py {a.envfile} <your .env.bak.localdev>")
