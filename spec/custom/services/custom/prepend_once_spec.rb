require 'rails_helper'

# Guards the dev-reload stacking bug described in
# custom/app/services/custom/prepend_once.rb: `to_prepare` re-runs on every
# Zeitwerk reload, and a reloadable overlay comes back as a NEW module object
# with the SAME name, which plain `Module#prepend` cannot recognise as already
# applied. On a non-reloadable target (a gem class such as
# Devise::PasswordsController) that stacks a fresh copy on every reload.
#
# The third example is the load-bearing one — the first two pass with a plain
# `prepend` too.
RSpec.describe Custom::PrependOnce do
  let(:target) { Class.new }

  def named_ancestor_count(klass, name)
    klass.ancestors.count { |ancestor| ancestor.name == name }
  end

  it 'prepends an overlay that is not applied yet' do
    stub_const('PrependOnceSpec::Overlay', Module.new)

    expect(described_class.call(target, PrependOnceSpec::Overlay)).to be(true)
    expect(target.ancestors).to include(PrependOnceSpec::Overlay)
  end

  it 'does not re-prepend the same module object' do
    stub_const('PrependOnceSpec::Overlay', Module.new)
    described_class.call(target, PrependOnceSpec::Overlay)

    expect(described_class.call(target, PrependOnceSpec::Overlay)).to be(false)
    expect(named_ancestor_count(target, 'PrependOnceSpec::Overlay')).to eq(1)
  end

  it 'does not stack a redefined module of the same name (the dev-reload case)' do
    stub_const('PrependOnceSpec::Overlay', Module.new)
    described_class.call(target, PrependOnceSpec::Overlay)

    # What Zeitwerk does on reload: same constant name, brand-new object.
    reloaded = Module.new
    stub_const('PrependOnceSpec::Overlay', reloaded)

    expect(described_class.call(target, reloaded)).to be(false)
    expect(named_ancestor_count(target, 'PrependOnceSpec::Overlay')).to eq(1)
  end

  it 'falls back to identity for anonymous overlays rather than matching on nil names' do
    anonymous = Module.new
    other_anonymous = Module.new
    target.prepend(other_anonymous)

    expect(described_class.call(target, anonymous)).to be(true)
    expect(target.ancestors).to include(anonymous)
  end

  it 'still prepends the same overlay onto a different target' do
    stub_const('PrependOnceSpec::Overlay', Module.new)
    described_class.call(target, PrependOnceSpec::Overlay)
    other_target = Class.new

    expect(described_class.call(other_target, PrependOnceSpec::Overlay)).to be(true)
  end

  # The wiring this helper was introduced for — asserted on the real objects,
  # so a future refactor of config/initializers/custom_prepends.rb that drops
  # the guard (or the prepend) is caught here and not in production.
  describe 'the fork overlays wired in config/initializers/custom_prepends.rb' do
    it 'applies the super_admin password-reset guard exactly once' do
      expect(
        named_ancestor_count(Devise::PasswordsController, 'Custom::DeviseOverrides::SuperAdminPasswordsGuard')
      ).to eq(1)
    end

    it 'applies the assignable-agents overlay exactly once' do
      expect(
        named_ancestor_count(Api::V1::Accounts::AssignableAgentsController,
                             'Custom::Api::V1::Accounts::AssignableAgentsController')
      ).to eq(1)
    end
  end
end
