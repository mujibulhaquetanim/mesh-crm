require 'rails_helper'

# Fork: a Facebook Page belongs to exactly ONE account, platform-wide.
#
# Upstream validates `page_id` uniqueness `scoped_to: :account_id`, and its
# unique index matched — `(page_id, account_id)`. So two accounts could each
# hold the same Page, and `Facebook::MessageCreator` resolves inbound by Page
# across every account with `.where(page_id: …).each`, delivering one
# customer's message into all of them. On a multi-tenant installation that is a
# cross-tenant message leak.
#
# The database is the control (migration 20260830120000, `UNIQUE (page_id)`);
# `Custom::Channel::FacebookPage` adds the matching validation so the failure is
# a clean 422 rather than a `PG::UniqueViolation` surfacing as a 500. This pins
# the model half — the half a future upstream merge could silently revert.
RSpec.describe 'Channel::FacebookPage page_id is globally unique' do
  before { stub_request(:post, /graph.facebook.com/) }

  it 'is enforced by the fork overlay, not only by upstream account scoping' do
    expect(Channel::FacebookPage.ancestors.map(&:to_s))
      .to include('Custom::Channel::FacebookPage')
  end

  it 'rejects a page_id already held by a DIFFERENT account' do
    existing = create(:channel_facebook_page)
    duplicate = build(
      :channel_facebook_page,
      account: create(:account),
      page_id: existing.page_id
    )

    expect(duplicate).not_to be_valid
    expect(duplicate.errors[:page_id]).to include('has already been taken')
  end

  it 'still allows a different page_id on another account' do
    create(:channel_facebook_page)
    other = build(
      :channel_facebook_page,
      account: create(:account),
      page_id: 'a-page-nobody-else-holds'
    )

    expect(other).to be_valid
  end

  it 'refuses the duplicate at the database level even if validation is skipped' do
    existing = create(:channel_facebook_page)
    duplicate = build(
      :channel_facebook_page,
      account: create(:account),
      page_id: existing.page_id
    )

    expect { duplicate.save!(validate: false) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end
end
