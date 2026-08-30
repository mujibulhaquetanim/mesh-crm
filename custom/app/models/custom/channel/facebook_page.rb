# Fork overlay for Channel::FacebookPage — a Facebook Page belongs to exactly
# ONE account, platform-wide.
#
# ## Why
#
# Upstream validates `page_id` uniqueness `scoped_to: :account_id`, and the
# table's unique index matched it: `(page_id, account_id)`. So two accounts
# could each hold a row for the same Page — and inbound is resolved by Page
# across every account:
#
#     # lib/integrations/facebook/message_creator.rb:32, :39
#     Channel::FacebookPage.where(page_id: response.sender_id).each do |page|
#
# `.each`, so one customer's Messenger message is delivered into every account
# holding that Page. On a multi-tenant installation that is a cross-tenant
# message leak. Two further sites take an arbitrary single match instead —
# `lib/integrations/facebook/delivery_status.rb:35` and
# `app/controllers/webhooks/instagram_controller.rb:62`, both `find_by` — so
# delivery receipts and IG events route non-deterministically rather than
# duplicating.
#
# A Page's Messenger webhook is registered against the Meta APP, not against an
# account, so there is no coherent way to route it to two owners. The sibling
# channels already hold the stronger invariant:
#
#     channel_instagram       UNIQUE (instagram_id)
#     channel_whatsapp        UNIQUE (phone_number)
#     channel_facebook_pages  UNIQUE (page_id, account_id)   <- the outlier
#
# which reads as an upstream inconsistency rather than a design decision.
#
# ## What this does
#
# The database is the real control — migration `20260830120000` replaces the
# composite index with `UNIQUE (page_id)`. This overlay adds the matching model
# validation so the failure surfaces as a clean 422 instead of a raw
# `PG::UniqueViolation` escaping as a 500.
#
# ⚠ Upstream's `scoped_to: :account_id` validation still runs — a prepended
# module ADDS a validator, it cannot remove one. That is harmless: global
# uniqueness implies per-account uniqueness, so the stronger rule decides. The
# only visible effect is that a same-account duplicate collects the "has already
# been taken" message twice. Deleting upstream's validator instead would be a
# core-flow edit, which this fork does not make (docs/fork/UPSTREAM_DIFF.md §0).
module Custom::Channel::FacebookPage
  def self.prepended(base)
    base.validates :page_id, uniqueness: true
  end
end
