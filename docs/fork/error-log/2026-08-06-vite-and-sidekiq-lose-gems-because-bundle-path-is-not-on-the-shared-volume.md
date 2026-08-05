# `vite` and `sidekiq` die on `GemNotFound` on every recreate — BUNDLE_PATH (`/gems`) is not on the shared bundle volume

- **Date**: 2026-08-06
- **Phase**: dev environment (post-upstream-sync bring-up, UPSTREAM_SYNC §6a)
- **Area**: docker

## Symptom

`vite` starts, installs node deps, then exits 1 immediately — so the SPA bundle
is never built and Chatwoot renders a blank page:

```text
vite-1  | Done in 43.5s
vite-1  | Ready to run Vite development server.
vite-1  | + exec bin/vite build --watch
vite-1  | /usr/local/bundle/gems/bundler-2.5.16/lib/bundler/definition.rb:600:in
vite-1  |   'Bundler::Definition#materialize': Could not find brakeman-8.0.5 in
vite-1  |   locally installed gems (Bundler::GemNotFound)
vite-1  |     from bin/vite:25:in '<main>'
```

`sidekiq` exits the same way. Running `bundle install` inside the **rails**
container succeeds —

```text
Bundle complete! 151 Gemfile dependencies, 377 gems now installed.
Bundled gems are installed into `/gems`
```

— and fixes `rails`, but `vite` keeps failing, and `rails` breaks again the next
time its container is recreated.

**This is not caused by an upstream sync.** `Gemfile.lock` was untouched by the
2026-08-06 merge; `brakeman (8.0.5)` was already pinned at the merge-base.

## Root cause

All three app containers share the `mesh-crm_bundle` volume, mounted at
`/usr/local/bundle` — which is `GEM_HOME`. But **`BUNDLE_PATH` is `/gems`**, a
path that is *not* on that volume:

```text
$ docker compose -p mesh-crm exec -T rails sh -c 'echo "$BUNDLE_PATH / $GEM_HOME"'
/gems / /usr/local/bundle

$ docker inspect mesh-crm-{rails,vite,sidekiq}-1 --format '{{range .Mounts}}{{.Name}} -> {{.Destination}}{{end}}'
mesh-crm_bundle -> /usr/local/bundle      (all three, identical)
```

So `bundle install` writes into the **container's own writable layer** at
`/gems`. Two consequences:

1. Gems installed in one container are invisible to its siblings — fixing
   `rails` does nothing for `vite`.
2. They live only as long as that container does. Any `docker compose up` that
   recreates it (a config change, an override, a `down`) throws them away.

The shared volume that *looks* like it exists to persist gems persists the wrong
directory.

## Fix

Install gems as part of the command, so the fix survives every recreate rather
than lasting until the next one. In the gitignored `docker-compose.override.yaml`:

```yaml
services:
  vite:
    command: ["sh", "-c", "bundle install && exec bin/vite build --watch"]

  sidekiq:
    command: ["sh", "-c", "bundle install && exec bundle exec sidekiq -C config/sidekiq.yml"]
```

Keep `exec` — without it the real process runs as a child of `sh`, which stops
it receiving signals and makes `docker compose stop` a 10s SIGKILL wait.

After the first run the install is a no-op against the image's cached gems, so
the added startup cost is ~1s, not a full install.

The real fix is to point `BUNDLE_PATH` at the shared volume (or drop the volume
and bake gems into the image), but that means editing `docker-compose.yaml` /
the Dockerfiles — OSS files this fork deliberately keeps close to upstream
(`UPSTREAM_DIFF.md` §0/§6). Left as a follow-up.

## Verification

```sh
docker compose -p mesh-crm up -d vite sidekiq
docker compose -p mesh-crm logs --tail=20 vite | grep 'built in'
#   built in 110412ms.

curl -s -o /dev/null -w '%{http_code} %{size_download}\n' \
  http://localhost:3000/vite-dev/assets/dashboard-*.js
#   200 3888529        <- SPA bundle actually serves

docker compose -p mesh-crm ps -a --format '{{.Service}}\t{{.State}}'
#   all five running
```

## Notes / related

- [2026-07-20 — rspec `test` service loses installed gems on every `run --rm` (BUNDLE_PATH not mounted)](./2026-07-20-rspec-test-service-loses-installed-gems.md)
  is the **same root cause**, found on the `test` service. It was read at the
  time as a `run --rm` quirk; it is not — it affects every long-lived service
  too, and bites on ordinary `up` after any recreate.
- [2026-08-06 — redis port collision leaves the container off its network](./2026-08-06-redis-port-collision-leaves-container-off-its-network.md)
  was hit in the same bring-up and masked this one at first.
- `UPSTREAM_SYNC.md` §6a step 2 says to wait for Vite's "built in <n>ms". If
  that line never appears, read the vite log — a dead container looks identical
  to a slow rebuild from the outside.
