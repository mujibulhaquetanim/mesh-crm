# The rebrand was written to the wrong database, and the Redis cache hid it for a day

- **Date**: 2026-09-25
- **Phase**: operations
- **Area**: db / ops

## Symptom

The owner reported that the inbox window title said "Chatwoot" again, and the
logo wasn't in the title bar. On 2026-09-24 the rebrand (`REBRAND_PRODUCTION.md`)
had been applied and verified from outside: `<title>Zasmate</title>`. About a
day later the live page served:

```text
<title>       Chatwoot     </title>
```

Reading the row through the running web container showed that the live
database had never been rebranded:

```text
db host: ep-aged-bonus-b2975446
before: "Chatwoot"
```

## Root cause

The title is `@global_config['INSTALLATION_NAME']`. `GlobalConfig` reads a
Redis cache (1-day expiry), and on a miss it loads from `installation_configs`.
The 2026-09-24 runner wrote "Zasmate" to a database the web container doesn't
read, and its read-back filled the **shared** Redis cache with that value. For
one day the website served the cached "Zasmate", so the outside check passed.
When the cache expired, the web container loaded its own row: "Chatwoot".

Which database the first run hit isn't recorded. The most likely route is
`docker compose run` against the fork's default `docker-compose.yaml` instead
of `-f docker-compose.prod.yaml`.

## Fix

The runbook's update was re-run through the running web container
(`docker compose -f docker-compose.prod.yaml exec -T rails …`). It printed the
host and the before value, set all six keys, and cleared the cache. The
outside check now serves `<title> Zasmate </title>`.

`REBRAND_PRODUCTION.md` now requires `exec` into the running `rails`
container, a printed database host, and a before/after for each value. Its
verification reads the **row** through the web container, because the page
check can pass off the cache.

## Also found: the icon (a separate cause)

The live favicons are the Zasmate artwork, byte-identical to the repo. But
they're served with `cache-control: public, max-age=31556952` (one year) at URLs
that never changed. A browser that saw the Chatwoot-era inbox keeps the old
icon: clear the site data, or check in a private window. `/favicon.ico` 404s
(upstream ships none either). Browsers use the `<link rel="icon">` PNGs, so
this is not the cause.

## Verification

```sh
docker compose -f docker-compose.prod.yaml exec -T rails bundle exec rails runner \
  'puts InstallationConfig.find_by(name: %q(INSTALLATION_NAME)).value'   # Zasmate
curl -sL https://inbox.zasmate.com/app/login | tr '\n' ' ' | grep -oE '<title>[^<]*</title>'
```
