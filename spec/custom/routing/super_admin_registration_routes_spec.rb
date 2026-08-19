require 'rails_helper'

# `SuperAdmin < User` and User is `:registerable`, so `devise_for :super_admins`
# used to route a full self-signup surface onto the operator console — including
# an unauthenticated GET /super_admin/sign_up + POST /super_admin, and an
# authenticated DELETE /super_admin that deletes the operator's own account.
# config/routes.rb now passes `skip: [:registrations]`.
#
# The second describe block is the other half of that change: skipping the
# routes does NOT make `devise_mapping.registerable?` false (that predicate
# reads the model's devise modules, not the routes), so Devise's stock
# devise/shared/_links partial would go on linking to the helper the skip just
# removed and take the operator's password-recovery pages down with a
# NoMethodError. custom/app/views/devise/shared/_links.html.erb is what stops
# that, and these are the pages that prove it.
RSpec.describe 'Super Admin registration routes', type: :request do
  describe 'the self-signup surface' do
    it 'does not route GET /super_admin/sign_up' do
      get '/super_admin/sign_up'

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route POST /super_admin (registrations#create)' do
      post '/super_admin', params: { super_admin: { email: 'x@example.com', password: 'Password1!' } }

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route GET /super_admin/cancel' do
      get '/super_admin/cancel'

      expect(response).to have_http_status(:not_found)
    end

    it 'does not route DELETE /super_admin (registrations#destroy — self account deletion)' do
      delete '/super_admin'

      expect(response).to have_http_status(:not_found)
    end

    it 'leaves the registration route out of the devise mapping' do
      expect(Devise.mappings[:super_admin].used_routes).not_to include(:registration)
    end
  end

  describe 'the recovery pages that render devise/shared/_links' do
    # History, because this reads oddly otherwise: BOTH of these pages used to
    # fail outright, before AND after this change, on a second and unrelated
    # bug — Devise's partial also links to `omniauth_authorize_path`, a helper
    # this app never generates (Chatwoot wires omniauth through
    # `OmniAuth::Builder` middleware rather than `Devise.setup`). That was
    # fixed on 2026-08-20 in the same view shadow, so these pages now render
    # for real; see super_admin_password_pages_spec.rb, which asserts the 200s
    # directly. These examples deliberately do NOT assert status — they assert
    # the narrower thing that is this change's business.
    #
    # What IS this change's business is that they must not fail on the helper
    # `skip: [:registrations]` deleted. Remove
    # custom/app/views/devise/shared/_links.html.erb and both examples go red
    # with `undefined method 'new_super_admin_registration_path'` — that is the
    # regression the shadow exists to prevent, and it was watched failing.
    #
    # Exceptions are let through rather than rendered: the rendered 500 page
    # quotes the failing template's source, and the shadow's own header comment
    # names the helper, so sniffing `response.body` would match the comment
    # rather than the failure. Written so it stays green either way if the
    # omniauth bug above is ever fixed and these pages start rendering.
    around do |example|
      original = Rails.application.env_config['action_dispatch.show_exceptions']
      Rails.application.env_config['action_dispatch.show_exceptions'] = :none
      example.run
    ensure
      Rails.application.env_config['action_dispatch.show_exceptions'] = original
    end

    def outcome_of
      yield
      response.body
    rescue StandardError => e
      "#{e.class}: #{e.message}"
    end

    it 'does not fail on the registration helper the skip removed (reset request page)' do
      outcome = outcome_of { get '/super_admin/password/new' }

      expect(outcome).not_to include('new_super_admin_registration_path')
    end

    it 'does not fail on the registration helper the skip removed (emailed reset form)' do
      super_admin = create(:super_admin, password: 'Password1!')
      token = super_admin.send_reset_password_instructions

      outcome = outcome_of { get "/super_admin/password/edit?reset_password_token=#{token}" }

      expect(outcome).not_to include('new_super_admin_registration_path')
    end

    it 'no longer defines the registration route helper at all' do
      expect { Rails.application.routes.url_helpers.new_super_admin_registration_path }
        .to raise_error(NoMethodError)
    end
  end
end
