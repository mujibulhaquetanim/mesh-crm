require 'rails_helper'

# The `super_admin_login/email` throttle is UPSTREAM code (#3830) that never
# did what its name says: it read a flat `email` param, but Devise namespaces
# this scope's fields, so the sign-in form posts `super_admin[email]`. The
# lookup always missed and the block returned `''` — which rack_attack treats
# as a legitimate key, putting every attempt on the whole instance into ONE
# shared bucket.
#
# Consequence, and the reason this is a fix rather than a tightening: any 5
# failed sign-ins — any source, any address, including addresses that do not
# exist — locked EVERY operator out of the console for 15 minutes.
#
# `super_admin_login/ip` is untouched and still bounds brute force per IP; this
# restores the second axis. See config/initializers/rack_attack.rb.
#
# Rack::Attack is disabled outside production by the last line of the
# initializer, so these examples enable it explicitly with a throwaway store —
# otherwise they pass vacuously. Every request sets REMOTE_ADDR because the
# initializer safelists 127.0.0.1, and a safelisted request skips all throttles.
RSpec.describe 'Rack::Attack super_admin login throttling', type: :request do
  around do |example|
    original_enabled = Rack::Attack.enabled
    original_store = Rack::Attack.cache.store

    Rack::Attack.enabled = true
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

    # Fixed windows keyed on `Time.now.to_i / period`: a run straddling a
    # boundary resets the count mid-example. Freezing pins one window.
    freeze_time { example.run }
  ensure
    Rack::Attack.cache.store = original_store
    Rack::Attack.enabled = original_enabled
  end

  def sign_in_attempt(email, ip: '1.2.3.4')
    post '/super_admin/sign_in',
         params: { super_admin: { email: email, password: 'wrong-password' } },
         env: { 'REMOTE_ADDR' => ip }
  end

  it 'throttles repeated attempts against ONE address across different IPs' do
    # Each request from a distinct IP, so the per-IP bucket stays at 1 and only
    # the email key can trip. This is the axis that was dead: before the fix the
    # key was '' for all of these, so they shared a bucket with everyone else's.
    5.times { |i| sign_in_attempt('target@company.com', ip: "10.0.0.#{i}") }
    expect(response).not_to have_http_status(:too_many_requests)

    sign_in_attempt('target@company.com', ip: '10.0.0.99')

    expect(response).to have_http_status(:too_many_requests)
  end

  # The regression that matters most: this is the lockout vector, and it is the
  # example that fails on the upstream code.
  it 'does NOT let attempts against one address lock out a different operator' do
    5.times { |i| sign_in_attempt('attacker-probe@example.com', ip: "10.0.1.#{i}") }

    sign_in_attempt('real-operator@company.com', ip: '10.0.2.1')

    expect(response).not_to have_http_status(:too_many_requests)
  end

  it 'does not bucket requests that carry no email at all' do
    # A blank key would pool these together and re-create the shared bucket
    # from a different direction.
    6.times { |i| post '/super_admin/sign_in', params: {}, env: { 'REMOTE_ADDR' => "10.0.3.#{i}" } }

    expect(response).not_to have_http_status(:too_many_requests)
  end

  it 'still throttles a single IP regardless of which address it targets' do
    # super_admin_login/ip, untouched — proves the per-email fix did not
    # weaken the brute-force control that was actually working.
    5.times { |i| sign_in_attempt("victim#{i}@company.com", ip: '10.0.4.1') }

    sign_in_attempt('victim-final@company.com', ip: '10.0.4.1')

    expect(response).to have_http_status(:too_many_requests)
  end
end
