module Custom::Account::PlanUsageAndLimits
  QUOTA_RESOURCES = %w[teams webhooks agent_bots labels custom_attribute_definitions automation_rules integrations].freeze

  # Limit keys stored in accounts.limits but NOT enforced by Chatwoot: the
  # agentic-AI (automated-workflow) cap is enforced by the external NestJS
  # backend and only displayed in the dashboard (docs/fork/ENTITLEMENTS.md,
  # CHATWOOT_ENGINE_INTEGRATION.md §5). They must pass schema validation so the
  # control plane can write them via the Platform API, but they get no
  # EntitlementService counter/guard.
  EXTERNAL_LIMIT_KEYS = %w[agentic_ai].freeze

  # Seat keys the core itself enforces from `usage_limits`: AgentBuilder's
  # `can_add_agent?` and the bulk-invite `available_agent_count` read `agents`.
  SEAT_LIMIT_KEYS = %w[agents inboxes].freeze

  # Fork keys resolve from the per-account limits jsonb only (the same source
  # Custom::EntitlementService enforces from) — no GlobalConfig fallback.
  #
  # `agents` and `inboxes` also read the account's own limits first. The MIT
  # core's `usage_limits` returns the installation maximum for both, and until
  # 2026-09-27 enterprise's override was what applied the per-account cap. In
  # production, which runs without enterprise/ (docs/fork/MIT_ONLY.md), without
  # this the seat cap the platform projects would be ignored by the core's own
  # guards. With enterprise present, `super` still supplies the fallback.
  def usage_limits
    base = super
    seats = SEAT_LIMIT_KEYS.to_h do |key|
      [key.to_sym, (self[:limits].to_h[key].presence || base[key.to_sym]).to_i]
    end
    fork_keys = QUOTA_RESOURCES.to_h do |resource|
      [resource.to_sym, (self[:limits].to_h[resource].presence || ChatwootApp.max_limit).to_i]
    end
    base.merge(seats).merge(fork_keys)
  end

  private

  # Replaces (not extends) the enterprise implementation because its schema uses
  # `additionalProperties: false`, which rejects the fork's quota keys.
  # Keep the base keys in sync with
  # enterprise/app/models/enterprise/account/plan_usage_and_limits.rb.
  def validate_limit_keys
    errors.add(:limits, ': Invalid data') unless self[:limits].is_a? Hash
    self[:limits] = {} if self[:limits].blank?

    base_keys = %w[inboxes agents captain_responses captain_documents emails]
    limit_schema = {
      'type' => 'object',
      'properties' => (base_keys + QUOTA_RESOURCES + EXTERNAL_LIMIT_KEYS).index_with { { 'type': 'number' } },
      'required' => [],
      'additionalProperties' => false
    }

    errors.add(:limits, ': Invalid data') unless JSONSchemer.schema(limit_schema).valid?(self[:limits])
  end
end
