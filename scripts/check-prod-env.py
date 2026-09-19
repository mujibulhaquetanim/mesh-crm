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

# ── stale-host detection ────────────────────────────────────────────────────
# Two checks, and the ORDER OF IMPORTANCE is the opposite of the order they were
# written in.
#
# ⚠ The pattern list below is an ENUMERATION OF KNOWN-BAD hosts, and it cannot
# catch the one that actually shipped. `EXTERNAL_LOGIN_URL` reached production
# holding `https://mesh-dash.mujibulhaquetanim.dev/login` — a dev DOMAIN, which
# is none of localhost/127.0.0.1/trycloudflare/ngrok — and this file printed
# "ok to ship". Every vendor who clicked the inbox was bounced to a dead host
# while every health check stayed green (troubleshooting/425).
#
# So the primary test is now the INVERSE: every URL-valued key must point at a
# host we expect in production. That excludes the next dev domain nobody has
# thought of yet, which an allowlist of bad patterns structurally cannot.
PROD_HOSTS = re.compile(r'(^|\.)(zasmate\.com|neon\.tech|r2\.cloudflarestorage\.com)$', re.I)
URLISH = re.compile(r'^[a-z][a-z0-9+.-]*://([^/@\s]+@)?([^/:?\s]+)', re.I)

foreign = []
for k, v in sorted(env.items()):
    if not v:
        continue
    m = URLISH.match(v)
    if not m:
        continue
    host = m.group(2).split(':')[0]
    if not PROD_HOSTS.search(host):
        foreign.append(f"{k} -> {host}")
if foreign:
    fails.append("URL keys pointing at a host we do not expect in production "
                 "(add it to PROD_HOSTS if it is legitimate): " + ", ".join(foreign))

# Kept as a second, narrower signal. It names the failure more specifically when
# it does fire, but it is no longer what the file relies on.
LOCAL = re.compile(r'localhost|127\.0\.0\.1|0\.0\.0\.0|trycloudflare|ngrok|host\.docker')
leaks = sorted(k for k, v in env.items() if v and LOCAL.search(v))
if leaks: fails.append("LOCAL dev values would reach production: " + ", ".join(leaks))

# ── the same hole one level down: hosts with no scheme ─────────────────────
# ⚠ URLISH requires `scheme://`. A BARE hostname never matches it, so neither
# check above can see one — `SMTP_ADDRESS=mailhog` slips through both and mail
# goes to a dev catcher that swallows it, which looks exactly like mail
# working. Same class as ts/425: a check that only inspects the shape of value
# it already expected.
#
# The compose service names are DERIVED from the compose file, not typed here,
# so a service added later is covered without anyone remembering this file
# exists. A single-label host that is NOT a service and NOT a production host
# fails; one that IS a service warns, because internal wiring is legitimate and
# only wrong when something outside the box has to resolve it.
def compose_services(path='docker-compose.production.yaml'):
    try:
        text = open(path).read()
    except OSError:
        return set()
    names, in_services = set(), False
    for line in text.splitlines():
        if re.match(r'^services:\s*$', line):
            in_services = True
            continue
        if in_services and re.match(r'^[A-Za-z]', line):
            break
        m = re.match(r'^  ([a-z0-9_-]+):\s*$', line)
        if in_services and m:
            names.add(m.group(1))
    return names

HOST_KEY = re.compile(r'(_HOST|_HOSTNAME|_ADDRESS|_SERVER|_DOMAIN)$', re.I)
SINGLE_LABEL = re.compile(r'^[a-z0-9]([a-z0-9-]*[a-z0-9])?$', re.I)
SERVICES = compose_services()

for k, v in sorted(env.items()):
    if not v or not HOST_KEY.search(k) or '://' in v:
        continue
    host = v.split(':')[0].strip()
    # Only single-label hosts. A dotted name (smtp.resend.com) is a plausible
    # public host and is left to the two checks above; a single label cannot
    # resolve anywhere but the compose network.
    if not SINGLE_LABEL.match(host):
        continue
    if host in SERVICES:
        warns.append(f"{k}={host} is a compose service. Correct for internal wiring, "
                     "wrong for anything a browser or a third party must resolve.")
    else:
        fails.append(f"{k}={host} is a BARE hostname — no scheme, so URLISH and the "
                     "LOCAL pattern both skip it. A single label resolves only inside "
                     "the compose network (SMTP_ADDRESS=mailhog is the shape: mail is "
                     "swallowed by a dev catcher and looks delivered).")

print(f"checked {len(env)} keys in {path}\n")
for f in fails: print("  FAIL ", f)
for w in warns: print("  warn ", w)
print()
print("RESULT:", "NOT SAFE TO SHIP" if fails else "ok to ship")
sys.exit(1 if fails else 0)
