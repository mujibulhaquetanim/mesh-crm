require 'rails_helper'

# A campaign is the second automated customer-facing outbound path on an
# account: `one_off` bulk-sends on a WhatsApp/SMS inbox, `ongoing` fires at
# website visitors. Neither goes through the platform agent, so on a meta-saas
# account both contradict ADR-0006's reply authority — and, just as concretely,
# they deliver through Chatwoot directly, so their messages never reach the
# platform's usage metering or audit trail.
#
# Blocking `send_message` on automations while leaving this open would close
# the door and leave the window.
#
# See custom/app/models/custom/campaign.rb.
RSpec.describe Campaign do
  # `agent_bots: 0` in the projected limits is what marks an account as run by
  # the control plane — see Custom::Concerns::PlatformReplyAuthority.
  let(:platform_account) { create(:account, limits: { 'agent_bots' => 0 }) }
  let(:stock_account) { create(:account) }

  def campaign_on(account, **attrs)
    inbox = create(:inbox, account: account, channel: create(:channel_widget, account: account))
    build(:campaign, account: account, inbox: inbox, **attrs)
  end

  describe 'on an account the control plane runs' do
    it 'refuses to create a campaign' do
      campaign = campaign_on(platform_account)

      expect(campaign).not_to be_valid
      expect(campaign.errors.full_messages.join).to include('Campaigns are disabled for this account')
    end

    it 'names metering and audit in the refusal, not just "invalid"' do
      campaign = campaign_on(platform_account)
      campaign.valid?

      expect(campaign.errors.full_messages.join).to include('usage metering', 'audit trail')
    end
  end

  describe 'on a stock Chatwoot account' do
    it 'leaves campaigns working exactly as upstream intends' do
      # No `limits` at all: never plan-synced, no platform agent, not ours to
      # police. This is the example that fails if the guard is ever made
      # unconditional.
      expect(campaign_on(stock_account)).to be_valid
    end
  end

  describe 'a campaign that already exists on a platform account' do
    # The guard's first effect on a live account must not be to strand the very
    # campaigns an operator is trying to switch off.
    let!(:existing) do
      campaign = campaign_on(platform_account)
      campaign.save(validate: false)
      campaign.reload
    end

    it 'can still be disabled' do
      expect(existing.update(enabled: false)).to be(true)
    end

    it 'can still be renamed while it stays enabled' do
      expect(existing.update(title: 'Renamed but untouched')).to be(true)
    end

    it 'can still be deleted' do
      expect { existing.destroy! }.to change(described_class, :count).by(-1)
    end

    it 'refuses re-arming a disabled campaign' do
      existing.update!(enabled: false)

      expect(existing.update(enabled: true)).to be(false)
    end

    it 'refuses changing what an enabled campaign sends' do
      expect(existing.update(message: 'Buy now')).to be(false)
    end

    it 'allows editing the message once it is disabled' do
      # Disabled means it cannot reach a customer, so the content is inert —
      # trapping edits there would block cleanup for no benefit.
      existing.update!(enabled: false)

      expect(existing.update(message: 'Draft copy')).to be(true)
    end
  end
end
