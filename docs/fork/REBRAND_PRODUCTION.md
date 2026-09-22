# Applying the Zasmate rebrand to a RUNNING instance

Merging the rebrand does not change a running install. This file is the part
that does.

## Why a deploy is not enough

`config/installation_config.yml` is a **seed**, not configuration.
`ConfigLoader` reads it and writes `installation_configs` rows the first time it
sees a key; after that the ROW is the source of truth and the YAML is ignored.
`GlobalConfig` — which is what every Vue view reads — serves those rows.

So after this branch deploys, a pre-existing instance still shows:

| Key | What the box still has | What it should be |
| --- | --- | --- |
| `INSTALLATION_NAME` | `Chatwoot` | `Zasmate` |
| `BRAND_NAME` | `Chatwoot` | `Zasmate` |
| `BRAND_URL` | `https://www.chatwoot.com` | `https://zasmate.com` |
| `WIDGET_BRAND_URL` | `https://www.chatwoot.com` | `https://zasmate.com` |

`INSTALLATION_NAME` is the one that matters most: it is the dashboard title, the
TOTP issuer an authenticator app files the vendor's account under, and — per the
platform notes — the single switch that decides whether disabled premium
features render as locked upsells or vanish entirely.

**`LOGO`, `LOGO_DARK` and `LOGO_THUMBNAIL` need no update.** Their values are
paths (`/brand-assets/logo.svg`), and the paths did not change — only the bytes
those paths serve. The deploy alone fixes the imagery.

## Do not write these rows with SQL

`serialized_value` is a `jsonb` column that Rails serializes with a **YAML**
coder (`serialize :serialized_value, coder: YAML, ...` — see the comment in
`app/models/installation_config.rb`, which calls it a breakage awaiting
migration). The stored shape is therefore not the JSON it looks like, and an
`UPDATE ... SET serialized_value = '{"value":"Zasmate"}'` produces a row that
reads back wrong. Go through the model.

## The change

```sh
bundle exec rails runner '
  { "INSTALLATION_NAME" => "Zasmate",
    "BRAND_NAME"        => "Zasmate",
    "BRAND_URL"         => "https://zasmate.com",
    "WIDGET_BRAND_URL"  => "https://zasmate.com" }.each do |name, value|
    config = InstallationConfig.find_by(name: name)
    if config.nil?
      warn "MISSING #{name} — ConfigLoader never seeded it; investigate before continuing"
      next
    end
    config.update!(value: value)
    puts "#{name} = #{config.reload.value}"
  end
  GlobalConfig.clear_cache
'
```

`InstallationConfig` clears the `GlobalConfig` cache in an `after_commit`, so the
explicit call is belt-and-braces; it costs nothing and makes the step readable.

### Do not reach for `ConfigLoader`

`ConfigLoader.new.process(reconcile_only_new: false)` would also do it, and it
is the wrong tool: that flag overwrites **every** config row with its YAML
default, including the ones an operator set deliberately through super-admin —
SMTP, Captain keys, feature toggles. Four targeted updates cannot do that.

## Verify — read it back from a new process

The cache is per-process, so checking in the same console that wrote the values
proves nothing about what a web worker will serve.

```sh
bundle exec rails runner '
  %w[INSTALLATION_NAME BRAND_NAME BRAND_URL WIDGET_BRAND_URL].each do |k|
    puts format("%-18s %s", k, GlobalConfig.get(k)[k])
  end
'
```

Then, from outside the box:

```sh
curl -s https://<inbox-host>/ | grep -o '<title>[^<]*</title>'
# expect: <title>Zasmate</title> — this is @global_config['INSTALLATION_NAME']

curl -sI https://<inbox-host>/favicon-32x32.png | head -1   # expect 200
curl -s  https://<inbox-host>/brand-assets/logo.svg | head -c 80
# expect an <svg …> carrying a base64 PNG, not the violet "M" placeholder
```

Load the login page in a private window — a cached favicon is the most likely
reason to think this failed when it did not. Check dark mode too: `logo_dark.svg`
is a separate file, and it is the one that would have been missed.
