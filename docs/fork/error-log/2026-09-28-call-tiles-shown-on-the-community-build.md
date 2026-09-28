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

The flag made it worse. The platform turns `channel_voice` **on** for the Pro and
Enterprise plans (agentic-str `chatwoot-features.ts`, `caps.voiceCallingEnabled`),
because those tiers will sell calling. On those accounts the flag also
switched on the call button in conversations and the WhatsApp inbox "Calls"
tab, and both hit the same missing routes. Only the Calls sidebar entry was
hidden, by upstream's `isCallsAvailable = isOnChatwootCloud || isEnterprise`.

## Fix

One signal, "can this build place calls", decided in the backend:

- `custom/app/models/custom/account.rb` (fork-only, on upstream's
  `Account.prepend_mod_with('Account')`): `feature_channel_voice?` is
  `Custom::Account.calls_served? && super`, and `calls_served?` is
  `Object.const_defined?(:Call)`. The production image has no `Call` model, so
  the flag reads as off there: no call button, no Calls tab, and
  `Channel::Whatsapp#voice_enabled?` is false. The stored bit is untouched, and
  the day upstream moves calling into the core, the flag works again with no
  fork change.
- `app/javascript/dashboard/fork/callChannels.js` (fork-only):
  `withoutUnservedCallChannels` drops `voice` and `whatsapp_call` unless
  `isOnChatwootCloud || channel_voice`. Upstream shows them as "Coming soon" or
  "Beta" with the flag off. Here a tile that can't be clicked isn't shown.
- `app/javascript/dashboard/routes/dashboard/settings/inbox/ChannelList.vue`:
  one import, and `return channels;` becomes
  `return withoutUnservedCallChannels(channels, …)`. This is a sanctioned §5
  exception in UPSTREAM_DIFF.md: Vue has no overlay mechanism.
- `scripts/fork-policy/check.py`: `policy.call_tiles_hidden`,
  `policy.call_tiles_rule`, `policy.voice_flag_served`, and a `policy.hook_point`
  for `Account`, so a sync that takes upstream's version of either file fails
  the check before a rebuild. `check.test.sh` breaks two of them on purpose.

Rejected:
- **Only the frontend filter, on `isEnterprise`** (the first version of this
  fix): it leaves the call button and the Calls tab live on Pro accounts, and
  it would keep the tiles hidden after upstream frees calling.
- **Sending `channel_voice: false` from the platform:** that is an API release,
  and the API release is blocked on MAIL_FROM. It would also turn calling off
  for the tiers that will sell it, so it would have to be undone later. The
  inbox knows what it can serve, so the inbox decides.
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
python3 scripts/fork-policy/check.py        # 86 passed, 0 failed — RESULT: ok to ship
bash scripts/fork-policy/check.test.sh      # 23 passed, 0 failed
# spec/custom, development tree (enterprise/ present): 300 examples, 0 failures
# spec/custom, CE tree (MIT_ONLY.md §Tests):            300 examples, 0 failures, 1 pending
#   (the pending one is the known enterprise-schema tripwire); zeitwerk:check "All is good!";
#   rails runner: Custom::Account.calls_served? => false, ChatwootApp.enterprise? => false
```

Proven:
- With `return channels;` restored in `ChannelList.vue`, the tile spec fails
  (1 failed | 4 passed).
- With the overlay's `Custom::Account.calls_served? &&` removed, `check.py`
  prints `FAIL policy.voice_flag_served` (a self-test case).
- `spec/custom/models/account_channel_voice_spec.rb` asserts, unstubbed, that
  `calls_served?` equals `ChatwootApp.enterprise?`. That holds in both trees.

**Released 2026-09-28 ~09:03 UTC** as `mesh-crm:f9ec7f401c` (digest
`sha256:7e8c7327aaa4…`, together with #52). Measured from outside after the release:

- The build's step `0/5` said `synced with upstream/develop` and
  `nothing moved from enterprise/ into core since b8eb7766f2`.
- `check.py --live https://inbox.zasmate.com`: 14 passed, 0 failed.
- `/api/v1/accounts/1/calls` and `/whatsapp_calls/1` still 404, and
  `/inboxes` 401. The fix hides the UI; the routes were never drawn.
- All 5 sampled `/vite/assets/*.js` served by `/app/login` exist in the image. The
  `['voice','whatsapp_call']` filter is in the built bundle.

**Signed-in check (2026-09-29):** the owner looked at the production inbox
signed in. *Add inbox* shows **no Voice or WhatsApp Call tile**, which was the
symptom that opened this entry. The conversation call button and the WhatsApp
Calls tab weren't reported separately. They read the same `channel_voice` flag,
which production reports off for all 4 accounts (the bit is stored only on
account 1).

## Notes / related

- [2026-09-24 paid-only surfaces visible on the community plan](./2026-09-24-paid-only-surfaces-visible-on-the-community-plan.md),
  the same class of defect (a surface keyed on something other than "does the
  backend serve this").
- Found while checking, and NOT fixed here: on `develop`,
  `settings/inbox/components/specs/TwilioHealth.spec.js` › "uses the installation
  name instead of ours in the health copy" fails. The copy says a literal
  "Zasmate" where the spec expects the installation name. It fails identically
  without this change. **Resolved as an expected failure** (the brand rule vs.
  upstream's runtime "Chatwoot" swap). The full suite has no other failure. See
  VENDOR_FEATURE_POLICY.md, "The one frontend spec the brand rule fails on purpose".
