# The fork would not boot without enterprise/: the injector assumes custom/ implies enterprise/

- **Date**: 2026-09-27
- **Phase**: MIT-only production (docs/fork/MIT_ONLY.md)
- **Area**: backend / boot

## Symptom

Found before release, on the first run of the fork suite against a tree with
`enterprise/` removed (the way `scripts/build-ce-image.sh` builds production):

```text
bin/rails aborted!
NoMethodError: undefined method 'const_defined?' for false (NoMethodError)
    mod&.const_defined?(name, false) && mod&.const_get(name, false)
/app/config/initializers/01_inject_enterprise_edition_module.rb:83:in 'InjectEnterpriseEditionModule#const_get_maybe_false'
/app/config/initializers/01_inject_enterprise_edition_module.rb:76:in 'block in InjectEnterpriseEditionModule#each_extension_for'
/app/app/models/application_record.rb:56:in '<main>'
…
/app/config/initializers/custom_prepends.rb:29:in 'block in <main>'
```

`rails db:schema:load` aborted, so the whole app, not just a feature, would
have been down on the first community-edition image.

## Root cause

Upstream never ships `custom/` without `enterprise/`. `ChatwootApp.extensions`
returns `%w[enterprise custom]` whenever `custom/` exists. For each extension,
`each_extension_for` resolves the namespace with `const_get_maybe_false`,
which returns `false` (not `nil`) when `Enterprise` isn't defined. The next
lookup then calls `false&.const_defined?`. `&.` only guards `nil`, so it raises.

## Fix

`config/initializers/01_inject_zz_custom_community_edition.rb` (fork-only)
prepends a guard onto `InjectEnterpriseEditionModule#const_get_maybe_false`:
an absent namespace resolves to "no extension". It's named to load right after
the injector and before anything can call `prepend_mod_with`. With
`enterprise/` present, behaviour is unchanged.

## Verification

```sh
# tree without enterprise/, as the build makes it (MIT_ONLY.md §Tests)
bundle exec rails zeitwerk:check && bundle exec rspec spec/custom
```

## Notes / related

- `DISABLE_ENTERPRISE=true` wouldn't have shown this: it leaves the folder in
  place, and on this fork it doesn't stop enterprise overlays loading either
  (MIT_ONLY.md).
- `scripts/fork-policy/check.py` `mit.*` checks guard the rest of the MIT-only setup.
