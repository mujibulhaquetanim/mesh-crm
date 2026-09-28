require 'rails_helper'

# Custom::Account#feature_channel_voice? — the calling flag reads as off on a
# build without the calling backend (production: MIT-only, no enterprise/).
RSpec.describe Custom::Account do
  let(:account) { create(:account) }

  before { account.enable_features!('channel_voice') }

  it 'is prepended onto Account' do
    expect(Account.ancestors).to include(described_class)
  end

  it 'serves calls exactly when the Call model ships (today: only with enterprise/)' do
    # Not stubbed: true in the development tree, false in the CE tree the
    # production image is built from (MIT_ONLY.md §Tests runs both).
    expect(described_class.calls_served?).to eq(ChatwootApp.enterprise?.present?)
  end

  context 'when the build serves calls' do
    before { allow(described_class).to receive(:calls_served?).and_return(true) }

    it 'honours the stored flag' do
      expect(account.feature_enabled?('channel_voice')).to be(true)
      expect(account.enabled_features).to include('channel_voice' => true)
    end
  end

  context 'when the build has no calling backend' do
    before { allow(described_class).to receive(:calls_served?).and_return(false) }

    it 'reads channel_voice as off, so the dashboard offers no call surface' do
      expect(account.feature_enabled?('channel_voice')).to be(false)
      expect(account.enabled_features).not_to have_key('channel_voice')
    end

    it 'keeps the stored bit, so calling comes back once the build serves it' do
      account.reload
      allow(described_class).to receive(:calls_served?).and_return(true)
      expect(account.feature_enabled?('channel_voice')).to be(true)
    end

    it 'leaves every other flag alone' do
      account.enable_features!('channel_email')
      expect(account.feature_enabled?('channel_email')).to be(true)
    end
  end
end
