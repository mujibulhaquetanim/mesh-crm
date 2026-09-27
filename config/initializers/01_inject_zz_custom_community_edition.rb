# frozen_string_literal: true

# Fork: let the extension injector run with custom/ but WITHOUT enterprise/.
#
# Production is built without the enterprise/ folder (docs/fork/MIT_ONLY.md).
# Upstream never ships that combination: its community image has neither
# folder, so `ChatwootApp.extensions` is `[]`. With custom/ present it returns
# `%w[enterprise custom]` unconditionally, and `each_extension_for` then looks
# up `Enterprise`, gets `false`, and calls `false.const_defined?` — the app
# fails to boot:
#
#   NoMethodError: undefined method 'const_defined?' for false
#     config/initializers/01_inject_enterprise_edition_module.rb:83
#
# This makes an ABSENT extension namespace resolve to "no extension" instead,
# which is what the injector already does for a missing module inside a present
# namespace. With enterprise/ present (development, specs) nothing changes.
#
# Named `01_inject_zz_…` so it loads right after the injector it refines and
# before any other initializer can trigger a `prepend_mod_with`. Kept in a
# fork-only file so the upstream injector merges clean on every sync. Ruby ≥ 3.0
# propagates a prepend onto InjectEnterpriseEditionModule to Module, which
# already prepended it.
module CustomCommunityEditionInjection
  private

  def const_get_maybe_false(mod, name)
    return false unless mod

    super
  end
end

InjectEnterpriseEditionModule.prepend(CustomCommunityEditionInjection)
