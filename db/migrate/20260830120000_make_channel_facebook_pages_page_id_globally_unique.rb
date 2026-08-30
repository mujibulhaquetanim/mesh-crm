class MakeChannelFacebookPagesPageIdGloballyUnique < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  # A Facebook Page may belong to exactly ONE account, platform-wide.
  #
  # It was unique on `(page_id, account_id)`, so two accounts could each hold a
  # row for the same Page — and `Facebook::MessageCreator` resolves inbound by
  # Page across every account:
  #
  #   # lib/integrations/facebook/message_creator.rb:32, :39
  #   Channel::FacebookPage.where(page_id: response.sender_id).each do |page|
  #
  # `.each`, so one customer's message is delivered into every account holding
  # that Page — a cross-tenant leak. Two further sites take an arbitrary single
  # match instead (`delivery_status.rb:35`, `webhooks/instagram_controller.rb:62`
  # both `find_by`), making routing non-deterministic rather than duplicated.
  #
  # This restores the invariant the sibling channels already have:
  #
  #   channel_instagram   UNIQUE (instagram_id)
  #   channel_whatsapp    UNIQUE (phone_number)
  #   channel_facebook_pages  UNIQUE (page_id, account_id)   <- the outlier
  #
  # A Page's Messenger webhook is app-scoped, not account-scoped, so there is no
  # coherent way to route it to two owners. The composite index was an upstream
  # inconsistency, not a design choice.

  def up
    guard_against_duplicates!

    # Ordered so uniqueness is never unenforced: the new constraint lands before
    # either old index is dropped.
    add_index :channel_facebook_pages, :page_id,
              unique: true,
              name: 'index_channel_facebook_pages_on_page_id_unique',
              algorithm: :concurrently,
              if_not_exists: true

    remove_index :channel_facebook_pages,
                 name: 'index_channel_facebook_pages_on_page_id_and_account_id',
                 algorithm: :concurrently,
                 if_exists: true

    # Redundant once page_id is unique — a unique btree serves every lookup the
    # plain one did.
    remove_index :channel_facebook_pages,
                 name: 'index_channel_facebook_pages_on_page_id',
                 algorithm: :concurrently,
                 if_exists: true
  end

  def down
    add_index :channel_facebook_pages, :page_id,
              name: 'index_channel_facebook_pages_on_page_id',
              algorithm: :concurrently,
              if_not_exists: true

    add_index :channel_facebook_pages, %i[page_id account_id],
              unique: true,
              name: 'index_channel_facebook_pages_on_page_id_and_account_id',
              algorithm: :concurrently,
              if_not_exists: true

    remove_index :channel_facebook_pages,
                 name: 'index_channel_facebook_pages_on_page_id_unique',
                 algorithm: :concurrently,
                 if_exists: true
  end

  private

  # `algorithm: :concurrently` leaves an INVALID index behind when the unique
  # build fails, which is a confusing state to hand an operator. Fail before
  # touching anything instead, naming the rows that have to be resolved by hand
  # — which account keeps a contested Page is a business decision, not one a
  # migration may make.
  def guard_against_duplicates!
    dupes = select_all(<<~SQL.squish).to_a
      SELECT page_id, COUNT(*) AS n, ARRAY_AGG(account_id ORDER BY account_id) AS account_ids
      FROM channel_facebook_pages
      GROUP BY page_id
      HAVING COUNT(*) > 1
    SQL
    return if dupes.empty?

    detail = dupes.map { |r| "page_id=#{r['page_id']} accounts=#{r['account_ids']}" }.join('; ')
    raise <<~MSG
      Cannot make channel_facebook_pages.page_id unique: #{dupes.length} Page(s) are held by more than one account.
        #{detail}
      Each Page must end up on exactly one account. Delete the channel row (and its inbox)
      from every account that should not keep it, then re-run this migration.
    MSG
  end
end
