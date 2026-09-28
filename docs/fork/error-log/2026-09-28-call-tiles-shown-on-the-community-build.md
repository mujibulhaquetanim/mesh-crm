# Voice and WhatsApp Call tiles shown on the community build

- **Date**: 2026-09-28
- **Phase**: operations (vendor-visible surface after the MIT-only release)
- **Area**: frontend

## Symptom

The owner saw **Voice** and **WhatsApp Call** under *Settings → Inboxes → Add
inbox* on the production inbox, which is built without `enterprise/`
(MIT_ONLY.md). Neither can work there. Measured on 2026-09-28 against
`https://inbox.zasmate.com`, unauthenticated:

```text
/api/v1/accounts/1/inboxes            -> 401  (route exists, needs a session)
/api/v1/accounts/1/calls              -> 404  (route not drawn)
/api/v1/accounts/1/whatsapp_calls/1   -> 404  (route not drawn)
```

## Root cause

Upstream's `ChannelList.vue` pushes both tiles unconditionally. Only the
`channel_voice` account flag makes them clickable, and it is `premium: true` in
`config/features.yml`. Everything behind them is enterprise-only: the `Call`
model (`enterprise/app/models/call.rb`, `enum provider: { twilio: 0, whatsapp: 1 }`),
the calls and WhatsApp-calls controllers, `Twilio::VoiceController`, and all
`Voice::*` / `Whatsapp::Call*` services. `config/routes.rb` draws their routes
inside `if ChatwootApp.enterprise?`, which is false once the folder is gone.

The other call surfaces were already hidden: the Calls sidebar entry by
upstream's `isCallsAvailable = isOnChatwootCloud || isEnterprise`, and the
conversation call button and inbox call settings by the `channel_voice` flag.
The *Add inbox* tiles were the one place with no gate at all.

## Fix

- `app/javascript/dashboard/fork/callChannels.js` (fork-only):
  `withoutUnservedCallChannels` drops `voice` and `whatsapp_call` unless
  `isOnChatwootCloud || isEnterprise`, the same condition upstream's
  `Sidebar.vue` uses for Calls.
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`:
  two imports, one `useConfig()` line, and `return channels;` becomes
  `return withoutUnservedCallChannels(channels, …)`. This is a sanctioned §5
  exception in UPSTREAM_DIFF.md: Vue has no overlay mechanism.
- `scripts/fork-policy/check.py`: `policy.call_tiles_hidden` and
  `policy.call_tiles_rule`, so a sync that takes upstream's `ChannelList.vue`
  wholesale fails the check before a rebuild. `check.test.sh` breaks it on
  purpose.

Rejected:
- **Turning the `channel_voice` flag off:** it already is. An off flag still
  renders both tiles, as "Coming soon" and "Beta".
- **Dashboard-scripts CSS (`DASHBOARD_SCRIPTS`):** a database row nobody
  reviews. The WhatsApp Call tile also shares its icon with the WhatsApp tile,
  so no stable selector exists.
- **Enabling calling:** `enterprise/LICENSE` needs a paid licence (ground rule 6).

Not covered: a hand-typed URL such as `/settings/inboxes/new/voice` still opens
the form. A vendor can't reach it from the UI.

## Verification

```sh
docker compose run --rm -T vite sh -c 'pnpm exec vitest run app/javascript/dashboard/fork/specs'
# Tests  5 passed (5)
python3 scripts/fork-policy/check.py        # 82 passed, 0 failed — RESULT: ok to ship
bash scripts/fork-policy/check.test.sh      # 21 passed, 0 failed
```

Proven: with `return channels;` restored in `ChannelList.vue`, the spec
`hides Voice and WhatsApp Call on the community build, even with channel_voice on`
fails (1 failed | 4 passed), and `check.py` prints `FAIL policy.call_tiles_hidden`.

After release, sign in as a vendor and open *Add inbox*: there are no Voice or
WhatsApp Call tiles.

## Notes / related

- [2026-09-24 paid-only surfaces visible on the community plan](./2026-09-24-paid-only-surfaces-visible-on-the-community-plan.md),
  the same class of defect (a surface keyed on something other than "does the
  backend serve this").
- Found while checking, and NOT fixed here: on `develop`,
  `settings/inbox/components/specs/TwilioHealth.spec.js` › "uses the installation
  name instead of ours in the health copy" fails. The copy says a literal
  "Zasmate" where the spec expects the installation name. It fails identically
  without this change.
