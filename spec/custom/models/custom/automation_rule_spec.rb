require 'rails_helper'

# The control plane's agent is the only reply authority on a meta-saas account
# (agentic-str ADR-0006). Captain is force-disabled and `agent_bots` is capped
# at 0 for that reason, but `automation_rules` is deliberately left non-zero —
# routing actions are useful and harmless. `send_message` / `send_attachment`
# are not: both build an outgoing, non-private message on the same
# `message_created` event the agent is answering, which is a second reply path
# racing the first.
#
# See custom/app/models/custom/automation_rule.rb.
RSpec.describe AutomationRule do
  # `agent_bots: 0` in the projected limits is what marks an account as run by
  # the control plane — see the overlay for why the guard keys off that.
  let(:account) { create(:account, limits: { 'agent_bots' => 0, 'automation_rules' => 3 }) }

  def rule_with(actions)
    build(:automation_rule, account: account, event_name: 'message_created', actions: actions)
  end

  def routing_actions
    [
      { 'action_name' => 'assign_team', 'action_params' => [1] },
      { 'action_name' => 'add_label', 'action_params' => %w[support] }
    ]
  end

  describe 'refusing customer-facing actions' do
    it 'rejects a rule that sends a message' do
      rule = rule_with([{ 'action_name' => 'send_message', 'action_params' => ['Hi there'] }])

      expect(rule).not_to be_valid
      expect(rule.errors[:actions].join).to include('send_message')
    end

    it 'rejects a rule that sends an attachment' do
      rule = rule_with([{ 'action_name' => 'send_attachment', 'action_params' => [1] }])

      expect(rule).not_to be_valid
      expect(rule.errors[:actions].join).to include('send_attachment')
    end

    it 'rejects the action even when it is buried among routing actions' do
      rule = rule_with(routing_actions + [{ 'action_name' => 'send_message', 'action_params' => ['Hi'] }])

      expect(rule).not_to be_valid
    end

    it 'rejects a symbol-keyed payload too' do
      # jsonb hash keys are not normalised until the row is serialised, so a
      # string-only read would let this shape through.
      rule = rule_with([{ action_name: 'send_message', action_params: ['Hi'] }])

      expect(rule).not_to be_valid
    end

    it 'tells the vendor why, not just that it is invalid' do
      rule = rule_with([{ 'action_name' => 'send_message', 'action_params' => ['Hi'] }])
      rule.valid?

      expect(rule.errors[:actions].join).to include('AI agent')
    end
  end

  describe 'leaving the rest of automations alone' do
    it 'saves a routing-only rule' do
      expect(rule_with(routing_actions)).to be_valid
    end

    it 'still allows a private note — internal only, never reaches the customer' do
      rule = rule_with([{ 'action_name' => 'add_private_note', 'action_params' => ['heads up'] }])

      expect(rule).to be_valid
    end

    it 'still allows notifying a team by email' do
      rule = rule_with([{ 'action_name' => 'send_email_to_team',
                          'action_params' => { 'message' => 'look at this', 'team_ids' => [1] } }])

      expect(rule).to be_valid
    end
  end

  describe 'accounts the control plane does not run' do
    # A stock Chatwoot account has no projected limits, so the premise the guard
    # rests on — an AI agent owns the replies here — does not hold and the guard
    # stays out of the way. This is also what keeps the upstream automation
    # suite green: unconditional, this validation reds 65 of its 116 examples.
    let(:unmanaged_account) { create(:account) }

    it 'still allows send_message' do
      rule = build(:automation_rule, account: unmanaged_account, event_name: 'message_created',
                                     actions: [{ 'action_name' => 'send_message', 'action_params' => ['Hi'] }])

      expect(rule).to be_valid
    end

    it 'still allows send_message when limits exist but agent bots are not capped at zero' do
      account_with_bots = create(:account, limits: { 'agent_bots' => 2 })
      rule = build(:automation_rule, account: account_with_bots, event_name: 'message_created',
                                     actions: [{ 'action_name' => 'send_message', 'action_params' => ['Hi'] }])

      expect(rule).to be_valid
    end
  end

  describe 'rules that predate the guard' do
    # The guard must not strand exactly the rules an operator needs to turn off:
    # it only runs when the action list itself is being written.
    let(:legacy_rule) do
      rule = rule_with([{ 'action_name' => 'send_message', 'action_params' => ['Hi'] }])
      rule.save(validate: false)
      rule.reload
    end

    it 'can still be deactivated' do
      expect(legacy_rule.update(active: false)).to be(true)
    end

    it 'can still be renamed' do
      expect(legacy_rule.update(name: 'Retiring this one')).to be(true)
    end

    it 'can still be deleted' do
      rule = legacy_rule # created outside the block, or the change matcher nets to zero

      expect { rule.destroy! }.to change(described_class, :count).by(-1)
    end

    it 'is refused the moment its actions are edited' do
      expect(legacy_rule.update(actions: legacy_rule.actions + [{ 'action_name' => 'add_label',
                                                                  'action_params' => %w[support] }])).to be(false)
    end

    it 'saves once the offending action is removed' do
      expect(legacy_rule.update(actions: routing_actions)).to be(true)
    end
  end
end
