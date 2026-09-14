# Fork: the SECOND assignee-picker path.
#
# `GET /api/v1/accounts/:id/assignable_agents` does NOT call
# `Inbox#assignable_agents` — it rebuilds the list itself as
# `inbox members ∩ … + Current.account.administrators`
# (app/controllers/api/v1/accounts/assignable_agents_controller.rb:14). This is
# the endpoint the dashboard's own API client hits
# (app/javascript/dashboard/api/assignableAgents.js), so scoping only the model
# would have left the visible dropdown still offering the platform service admin.
#
# ⚠ This used to say "upstream ships no `prepend_mod_with` hook on this class".
# That stopped being true in the 2026-09-14 upstream sync: upstream now calls
# `Api::V1::Accounts::AssignableAgentsController.prepend_mod_with(...)` itself,
# which resolves this module by name and prepends it.
#
# The manual entry in config/initializers/custom_prepends.rb is therefore now a
# no-op — `Custom::PrependOnce` matches by NAME, sees upstream's prepend of the
# same name, and declines. It is kept deliberately rather than deleted: this
# overlay is a security control (it hides the platform service admin from the
# assignee picker), and a belt-and-braces prepend that costs one no-op is worth
# more than the line it saves if upstream ever drops the hook again.
module Custom
  module Api
    module V1
      module Accounts
        module AssignableAgentsController
          def index
            super
            @assignable_agents = Custom::PlatformManagedUsers.reject_from(
              @assignable_agents,
              Current.account
            )
          end
        end
      end
    end
  end
end
