require 'rails_helper'

# Companion to the `super_admin_login/*` throttles: /super_admin/sign_in was
# rate-limited, /super_admin/password was not, which left the operator scope's
# second login-shaped path (stock Devise::PasswordsController — see
# docs/fork/SUPER_ADMIN.md §4.3) open to unlimited reset-mail floods at a
# guessed operator address and unlimited `reset_password_token` guesses.
#
# Rack::Attack is disabled outside production by the last line of
# config/initializers/rack_attack.rb, so these examples turn it on explicitly
# and hand it a throwaway in-memory store. Without that the throttles under
# test never run and every example passes vacuously.
#
# Every request sets REMOTE_ADDR: the initializer safelists 127.0.0.1, which is
# what a request spec would otherwise send, and a safelisted request skips all
# throttles.
RSpec.describe 'Rack::Attack super_admin password-reset throttling', type: :request do
  around do |example|
    original_enabled = Rack::Attack.enabled
    original_store = Rack::Attack.cache.store

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    # rack_attack counts into a FIXED window keyed on `Time.now.to_i / period`,
    # so a run that happens to straddle a boundary resets the count mid-example
    # and the last request comes in under the limit. Observed once as a flake in
    # a full-suite run. Freezing time pins every request to one window.
    freeze_time { example.run }
  ensure
    Rack::Attack.cache.store = original_store
    Rack::Attack.enabled = original_enabled
  end

  let(:super_admin) { create(:super_admin, password: 'Password1!') }

  def request_reset(email, ip: '1.2.3.4')
    post '/super_admin/password',
         params: { super_admin: { email: email } },
         env: { 'REMOTE_ADDR' => ip }
  end

  describe 'POST /super_admin/password (request reset instructions)' do
    it 'throttles a single IP after 5 attempts' do
      5.times { |i| request_reset("nobody#{i}@example.com") }
      expect(response).not_to have_http_status(:too_many_requests)

      request_reset('nobody-6@example.com')

      expect(response).to have_http_status(:too_many_requests)
    end

    it 'throttles a single target email across different IPs' do
      # Every request comes from a different IP, so the per-IP bucket stays at
      # 1 — this can only trip on the email key.
      5.times { |i| request_reset(super_admin.email, ip: "10.0.0.#{i}") }
      expect(response).not_to have_http_status(:too_many_requests)

      request_reset(super_admin.email, ip: '10.0.0.99')

      expect(response).to have_http_status(:too_many_requests)
    end

    it 'keys the email bucket per address — a second operator is unaffected' do
      5.times { |i| request_reset(super_admin.email, ip: "10.0.1.#{i}") }

      request_reset('someone-else@example.com', ip: '10.0.1.99')

      expect(response).not_to have_http_status(:too_many_requests)
    end

    it 'does not lump email-less requests into one shared bucket' do
      # A blank discriminator would put all of them in the SAME bucket, so a
      # single client could exhaust it and lock every operator out of recovery.
      10.times { |i| request_reset('', ip: "10.0.2.#{i}") }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  describe 'PUT /super_admin/password (submit a reset token)' do
    let(:token_guess) do
      { super_admin: { reset_password_token: 'guess', password: 'NewStr0ng!Pass9',
                       password_confirmation: 'NewStr0ng!Pass9' } }
    end

    it 'throttles token guesses from a single IP after 5 attempts' do
      5.times { put '/super_admin/password', params: token_guess, env: { 'REMOTE_ADDR' => '9.9.9.9' } }
      expect(response).not_to have_http_status(:too_many_requests)

      put '/super_admin/password', params: token_guess, env: { 'REMOTE_ADDR' => '9.9.9.9' }

      expect(response).to have_http_status(:too_many_requests)
    end
  end

  describe 'blast radius' do
    it 'leaves the tenant password-reset path on its own bucket' do
      5.times { |i| request_reset("nobody#{i}@example.com", ip: '7.7.7.7') }

      post '/auth/password', params: { email: 'tenant@example.com' }, env: { 'REMOTE_ADDR' => '7.7.7.7' }

      expect(response).not_to have_http_status(:too_many_requests)
    end
  end

  # The discriminator block runs on unvalidated request params, before any
  # controller sees them. Anything it raises escapes inside the middleware, so
  # these are asserted against the block directly rather than through a request
  # (a controller-level 500 on the same input would mask the difference).
  describe 'the email discriminator block' do
    subject(:discriminator) { Rack::Attack.throttles['super_admin_password/email'].block }

    def mock_request(query, method: 'POST')
      Rack::Attack::Request.new(Rack::MockRequest.env_for("/super_admin/password#{query}", method: method))
    end

    it 'returns nil rather than raising when super_admin is a crafted scalar' do
      # `params.dig('super_admin', 'email')` would raise TypeError here —
      # String has no #dig.
      expect(discriminator.call(mock_request('?super_admin=x'))).to be_nil
    end

    it 'returns a plain string bucket key rather than raising when the email is a crafted array' do
      expect(discriminator.call(mock_request('?super_admin[email][]=a'))).to be_a(String)
    end

    it 'normalises case and whitespace so one address is one bucket' do
      expect(discriminator.call(mock_request('?super_admin[email]=%20OPS@Example.com%20'))).to eq('ops@example.com')
    end

    it 'ignores requests to the path with a verb that cannot reset anything' do
      expect(discriminator.call(mock_request('?super_admin[email]=ops@example.com', method: 'GET'))).to be_nil
    end
  end
end
