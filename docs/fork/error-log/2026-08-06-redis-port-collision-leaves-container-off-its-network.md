# Redis loses its NETWORK (not just its port) when meta-saas already holds 6379 — rails cannot resolve `redis`, and migrations that enqueue jobs die

- **Date**: 2026-08-06
- **Phase**: dev environment (post-upstream-sync bring-up, UPSTREAM_SYNC §6a)
- **Area**: docker

## Symptom

`rails db:migrate` aborted partway through a 13-migration backlog:

```text
== 20260803000000 EnqueueCopyCaptainAutoResolveModeToAssistantsJob: migrating =
bin/rails aborted!
StandardError: An error has occurred, this and all later migrations canceled:
Operation timed out - user specified timeout: 1s
Caused by:
RedisClient::CannotConnectError: Operation timed out - user specified timeout: 1s (redis://redis:6379)
Caused by:
Errno::ETIMEDOUT: Operation timed out - user specified timeout: 1s
```

`docker compose ps` reported redis **running and healthy**, which is what makes
this misleading. The real state:

```text
$ docker compose -p mesh-crm exec -T rails sh -c 'nc -zv redis 6379'
nc: bad address 'redis'

$ docker inspect mesh-crm-redis-1 --format '{{.HostConfig.NetworkMode}} / {{.NetworkSettings.Networks}}'
mesh-crm_default / map[]          <- declared network, attached to NONE
```

`sidekiq` and `vite` also exited 1. On a later `up` the daemon said it outright:

```text
Error response from daemon: failed to set up container networking:
Bind for 0.0.0.0:6379 failed: port is already allocated
```

## Root cause

**Both compose stacks publish host port 6379**, and they are meant to run at the
same time (the meta-saas API talks to Chatwoot):

| stack | file | container | host port |
|---|---|---|---|
| agentic-str | `docker-compose.yml` | `meta-saas-redis` | `6379` |
| mesh-crm | `docker-compose.yaml` | `mesh-crm-redis` | `6379` |

Whichever starts second fails to bind. The damaging part is *how* it fails:
the container is still **created and started**, and its healthcheck (which runs
`redis-cli ping` **inside** the container) passes — so `ps` shows
`running (healthy)` — but it is left attached to **no network at all**. The
compose DNS alias `redis` therefore does not exist, and every container-to-
container dial fails with a 1s timeout rather than a connection refusal.

Only the migration that **enqueues a Sidekiq job** surfaced it; the twelve
pure-schema migrations before it never touched Redis, so the backlog applied
7-of-13 and then stopped, looking like a migration bug rather than a network one.

## Fix

mesh-crm's redis does **not** need a host port — `rails`/`sidekiq` reach it
in-network as `redis:6379`. meta-saas keeps 6379 because its API runs on the
**host** and dials the published port. So remap only this side:

```yaml
# docker-compose.override.yaml
services:
  redis:
    ports: !override
      - "6380:6379"
```

`!override` (not a plain list) is required — compose *merges* `ports` by
default, so without it you get both `6379` and `6380` and the collision remains.

The override is **gitignored**, not committed: this repo is a Chatwoot fork
whose conflict surface is deliberately minimal (`UPSTREAM_DIFF.md` §0), and
`docker-compose.yaml` is already the one OSS file that conflicts when upstream
reworks the dev env.

## Verification

```sh
docker compose -p mesh-crm up -d
docker compose -p mesh-crm exec -T rails sh -c 'getent hosts redis'
#   172.20.0.2  redis  redis            <- resolves

docker inspect mesh-crm-redis-1 --format '{{.NetworkSettings.Networks}}' | grep -q mesh-crm_default && echo attached

docker compose -p mesh-crm exec -T rails bundle exec rails db:migrate:status | grep -c '^\s*down'
#   0
```

## Notes / related

- Do **not** trust `docker compose ps` for this class of fault: the healthcheck
  runs inside the container and passes while the container is unreachable from
  every sibling. Check `.NetworkSettings.Networks` instead.
- [2026-07-27 — REDIS_URL pointed at a compose service the fork had deleted](./2026-07-27-redis-service-missing-from-compose.md)
  is the other half of this: that one was a missing service, this one is a
  present service that is silently unreachable.
- [2026-08-06 — vite/sidekiq lose their gems on every recreate](./2026-08-06-vite-and-sidekiq-lose-gems-because-bundle-path-is-not-on-the-shared-volume.md)
  was hit in the same bring-up.
- `UPSTREAM_SYNC.md` §6a assumes `db:migrate` just works. It does not when the
  stack has a port collision, and the failure names Redis, not the port.
