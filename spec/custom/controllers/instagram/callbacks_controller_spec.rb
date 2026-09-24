require 'rails_helper'

# Fork override: GET /instagram/callback without a verifiable `state` must not
# 500.
#
# Upstream runs the whole flow even when `state` is missing or forged. The code
# exchange then fails, the rescue calls `redirect_to_error_page`, and that
# builds `app_new_instagram_inbox_url(account_id: nil)`. The route requires
# :account_id, so the URL helper raises INSIDE the rescue and the request
# escapes as a 500. Any bare hit on the callback (a crawler, a copied link, an
# expired state) produced one.
#
# See custom/app/controllers/custom/instagram/callbacks_controller.rb.
RSpec.describe 'Instagram::CallbacksController (fork state guard)', type: :request do
  let(:account) { create(:account) }
  let(:app_secret) { 'instagram-app-secret-for-spec' }

  before do
    create(:installation_config, name: 'INSTAGRAM_APP_SECRET', value: app_secret)
    GlobalConfig.clear_cache

    # Answer the code exchange the way Instagram does for a bad code: a 400
    # OAuthException. Without this stub WebMock raises NetConnectNotAllowedError,
    # which is NOT a StandardError, so it would skip upstream's `rescue` entirely
    # and 500 by a path production never takes. The real path is: OAuth2::Error
    # → rescue → redirect_to_error_page → URL helper raises on a nil account_id.
    stub_request(:post, 'https://api.instagram.com/oauth/access_token')
      .to_return(
        status: 400,
        headers: { 'Content-Type' => 'application/json' },
        body: { error_type: 'OAuthException', code: 400, error_message: 'Invalid authorization code' }.to_json
      )
  end

  it 'redirects a bare hit (no code, no state) to /app instead of raising' do
    get '/instagram/callback'

    expect(response).to have_http_status(:found)
    expect(response.location).to end_with('/app')
  end

  it 'never exchanges a code that arrives with a state it cannot verify' do
    get '/instagram/callback', params: { code: 'attacker-code', state: 'not-a-signed-token' }

    expect(response).to have_http_status(:found)
    expect(response.location).to end_with('/app')
    expect(a_request(:any, /instagram\.com/)).not_to have_been_made
  end

  it "leaves upstream's flow alone when the state IS valid" do
    token = JWT.encode({ sub: account.id, iat: Time.current.to_i }, app_secret, 'HS256')

    get '/instagram/callback', params: { error: 'access_denied', error_description: 'User denied', state: token }

    expect(response).to have_http_status(:found)
    expect(response.location).to include("/app/accounts/#{account.id}/settings/inboxes/new/instagram")
    expect(response.location).to include('error_type=access_denied')
  end
end
