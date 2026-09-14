#!/usr/bin/env python3
"""Preflight for /srv/mesh-crm/.env before scp. Prints PASS/FAIL only, never values."""
import re, sys

path = sys.argv[1] if len(sys.argv) > 1 else '.env'
env = {}
for line in open(path):
    m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line.rstrip('\n'))
    if m and not line.lstrip().startswith('#'):
        env[m.group(1)] = m.group(2).strip().strip('"').strip("'")

fails, warns = [], []
def need(k, cond, msg):
    (fails if not cond else warns if False else []).append(f"{k}: {msg}") if not cond else None

SECRETS = ['SECRET_KEY_BASE', 'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY',
           'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY',
           'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT']
for k in SECRETS:
    v = env.get(k, '')
    if not v:                           fails.append(f"{k}: MISSING/empty — the boot guard will refuse")
    elif v.startswith('replace_with'):  fails.append(f"{k}: still placeholder text")
    elif len(v) < 32:                   fails.append(f"{k}: suspiciously short ({len(v)} chars)")
if len({env.get(k,'') for k in SECRETS if env.get(k)}) < len([k for k in SECRETS if env.get(k)]):
    fails.append("the four secrets: at least two share a value — they must all differ")

db = env.get('CRM_DATABASE_URL', '')
if not db:                              fails.append("CRM_DATABASE_URL: MISSING — compose refuses (:? guard)")
else:
    if 'mesh-api' in db:                fails.append("CRM_DATABASE_URL: names mesh-api — that is the PLATFORM db. DESTRUCTIVE.")
    if 'sslmode=verify-full' not in db: fails.append("CRM_DATABASE_URL: not sslmode=verify-full")
    if 'ap-southeast' in db:            fails.append("CRM_DATABASE_URL: still points at SINGAPORE")
    if 'mesh-inbox' not in db:          warns.append("CRM_DATABASE_URL: does not mention mesh-inbox — confirm it is the Chatwoot project")

fe = env.get('CRM_FRONTEND_URL', '')
if not fe:                              fails.append("CRM_FRONTEND_URL: MISSING — compose refuses (:? guard)")
elif 'example.com' in fe:               fails.append("CRM_FRONTEND_URL: copied from the error message's example")
elif not fe.startswith('https://'):     fails.append("CRM_FRONTEND_URL: not https")

# Object storage. config/storage.yml's s3_compatible service reads every field as
# ENV.fetch('STORAGE_…', '') — it defaults to an EMPTY STRING, not an error. So a
# missing credential boots healthy and fails on the first attachment upload, in
# production, with no signal at boot. That is why this block is FAIL, not warn.
svc = env.get('CRM_ACTIVE_STORAGE_SERVICE', '')
S3_KEYS = ['STORAGE_ENDPOINT','STORAGE_ACCESS_KEY_ID','STORAGE_SECRET_ACCESS_KEY','STORAGE_BUCKET_NAME']
if not svc:
    fails.append("CRM_ACTIVE_STORAGE_SERVICE: unset — compose defaults it to s3_compatible "
                 "with BLANK credentials; attachments fail on first upload, silently at boot")
elif svc == 's3_compatible':
    miss = [k for k in S3_KEYS if not env.get(k)]
    if miss: fails.append("storage is s3_compatible but these are unset: " + ", ".join(miss))
    if env.get('STORAGE_ENDPOINT','').startswith('http://'):
        fails.append("STORAGE_ENDPOINT: plain http — attachment URLs redirect the browser here")
    if 'r2.cloudflarestorage.com' in env.get('STORAGE_ENDPOINT','') and env.get('STORAGE_REGION') != 'auto':
        warns.append("STORAGE_REGION: R2 expects 'auto'")
    if 'r2.cloudflarestorage.com' in env.get('STORAGE_ENDPOINT','') and env.get('STORAGE_FORCE_PATH_STYLE') != 'true':
        warns.append("STORAGE_FORCE_PATH_STYLE: should be 'true' against a custom endpoint")
elif svc == 'local':
    warns.append("storage=local: survives redeploys (prod_storage volume) but sits on ONE box "
                 "with no backup; moving to R2 later needs an active_storage_blobs.service_name update")
else:
    warns.append(f"CRM_ACTIVE_STORAGE_SERVICE={svc} — not a service this fork configures")

COMPOSE_OWNS = ['FRONTEND_URL','RAILS_ENV','RAILS_LOG_TO_STDOUT','REDIS_URL','ACTIVE_STORAGE_SERVICE',
                'POSTGRES_HOST','POSTGRES_PORT','POSTGRES_DATABASE','POSTGRES_USERNAME',
                'POSTGRES_PASSWORD','POSTGRES_SSLMODE']
present = [k for k in COMPOSE_OWNS if env.get(k)]
if present: warns.append("compose already sets these; remove to avoid misleading the next reader: " + ", ".join(present))

# The check that matters most: a secret REUSED from the dev box. Presence and
# length cannot tell a dev secret from a production one, so compare directly.
if len(sys.argv) > 2:
    dev = {}
    for line in open(sys.argv[2]):
        m = re.match(r'\s*([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$', line.rstrip('\n'))
        if m and not line.lstrip().startswith('#'):
            dev[m.group(1)] = m.group(2).strip().strip('"').strip("'")
    reused = [k for k in SECRETS if env.get(k) and env.get(k) == dev.get(k)]
    if reused:
        fails.append("REUSED FROM THE DEV BOX, regenerate: " + ", ".join(reused))
else:
    warns.append("no dev .env given for comparison — rerun with a 2nd arg to catch secrets copied from the dev box")

LOCAL = re.compile(r'localhost|127\.0\.0\.1|0\.0\.0\.0|trycloudflare|ngrok|host\.docker')
leaks = sorted(k for k, v in env.items() if v and LOCAL.search(v))
if leaks: fails.append("LOCAL dev values would reach production: " + ", ".join(leaks))

print(f"checked {len(env)} keys in {path}\n")
for f in fails: print("  FAIL ", f)
for w in warns: print("  warn ", w)
print()
print("RESULT:", "NOT SAFE TO SHIP" if fails else "ok to ship")
sys.exit(1 if fails else 0)
