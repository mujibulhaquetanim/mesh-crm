require 'rails_helper'

# Pins the truthiness table of the single SUPER_ADMIN_ENFORCE_MFA reader.
# Three surfaces call this — the sign-in check, the password-reset guard, and
# the sign-in form's otp_attempt field — and they have to agree, so the values
# that count as "on" are behaviour, not an implementation detail.
#
# These are the semantics the three inlined copies had before they were merged
# into this predicate (ActiveModel::Type::Boolean), asserted so the merge can
# be shown to have changed nothing.
RSpec.describe Custom::SuperAdminMfa do
  describe '.enforced?' do
    it 'is falsey when the flag is unset (the default — enforcement is opt-in)' do
      with_modified_env(SUPER_ADMIN_ENFORCE_MFA: nil) do
        expect(described_class).not_to be_enforced
      end
    end

    %w[true TRUE 1 t T on ON yes].each do |value|
      it "is truthy for #{value.inspect}" do
        with_modified_env(SUPER_ADMIN_ENFORCE_MFA: value) do
          expect(described_class).to be_enforced
        end
      end
    end

    # ActiveModel::Type::Boolean's FALSE_VALUES — everything else is true, which
    # is why an empty string must be checked explicitly rather than assumed.
    ['false', 'FALSE', '0', 'f', 'off', ''].each do |value|
      it "is falsey for #{value.inspect}" do
        with_modified_env(SUPER_ADMIN_ENFORCE_MFA: value) do
          expect(described_class).not_to be_enforced
        end
      end
    end

    it 're-reads ENV on every call rather than memoizing the first answer' do
      with_modified_env(SUPER_ADMIN_ENFORCE_MFA: 'true') do
        expect(described_class).to be_enforced
      end

      with_modified_env(SUPER_ADMIN_ENFORCE_MFA: 'false') do
        expect(described_class).not_to be_enforced
      end
    end
  end
end
