# Idempotent `Module#prepend` for the fork's `to_prepare` overlays
# (config/initializers/custom_prepends.rb).
#
# The problem it exists for: `to_prepare` runs on every reload in development,
# and `Module#prepend` skips a module already in the ancestor chain — but only
# by object IDENTITY. For a reloadable overlay that is not the same thing as
# "by name": Zeitwerk discards the old `Custom::…` module on each reload and
# defines a brand-new object under the same name, which `prepend` has never
# seen, so it goes in again.
#
# That is harmless while the TARGET is reloadable too, because it is discarded
# and rebuilt alongside the overlay. It is not harmless when the target comes
# from a gem — `Devise::PasswordsController` is loaded once and survives every
# reload, so each edit-and-reload cycle prepends another copy onto the same
# class. The ancestor chain grows without bound, its lower layers are dead
# module objects, and every `super` walks all of them.
#
# So: match by NAME. Anonymous modules have no name to match on, so they fall
# back to identity — that keeps the helper honest rather than silently treating
# every unnamed ancestor as "already applied".
#
# Known dev-only trade-off, and the right one: once an overlay is in the
# ancestor chain of a non-reloadable class, editing the overlay stops taking
# effect until the server restarts. A stale overlay announces itself the first
# time you exercise it; a 40-deep ancestor chain does not. Production is
# unaffected either way — under eager loading `to_prepare` runs exactly once,
# so nothing here ever fires a second time.
#
# Compact class form for the same namespace reason as the sibling
# `Custom::SuperAdminMfaEnroll` — see docs/fork/UPSTREAM_DIFF.md §2.
class Custom::PrependOnce
  # Returns true when it actually prepended, false when it was already applied.
  def self.call(target, overlay)
    return false if applied?(target, overlay)

    target.prepend(overlay)
    true
  end

  def self.applied?(target, overlay)
    # An anonymous overlay has `name == nil`, and so does every other anonymous
    # module in the chain — comparing names there would match the wrong thing.
    return target.ancestors.include?(overlay) if overlay.name.nil?

    target.ancestors.any? { |ancestor| ancestor.name == overlay.name }
  end
end
