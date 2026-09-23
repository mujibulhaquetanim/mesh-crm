require 'rails_helper'

# Messenger webhook subscription handshake (GET /bot): Meta sends
# `hub.verify_token`, and the endpoint must echo `hub.challenge` only when that
# token equals the installation's FB_VERIFY_TOKEN. See
# custom/app/services/custom/facebook_messenger_verify_token.rb.
RSpec.describe 'Messenger webhook verify token', type: :request do
  let(:challenge) { 'challenge-1234' }

  def handshake(token)
    params = { 'hub.mode' => 'subscribe', 'hub.challenge' => challenge }
    params['hub.verify_token'] = token unless token.nil?
    get '/bot', params: params
  end

  def configure(value)
    allow(GlobalConfigService).to receive(:load).and_call_original
    allow(GlobalConfigService).to receive(:load).with('FB_VERIFY_TOKEN', '').and_return(value)
  end

  context 'when FB_VERIFY_TOKEN is configured' do
    before { configure('expected-token') }

    it 'echoes the challenge for the configured token' do
      handshake('expected-token')
      expect(response.body).to eq(challenge)
    end

    it 'does not echo the challenge for a different token' do
      handshake('some-other-token')
      expect(response.body).not_to eq(challenge)
    end

    it 'does not echo the challenge when no token is sent' do
      handshake(nil)
      expect(response.body).not_to eq(challenge)
    end
  end

  context 'when FB_VERIFY_TOKEN is not configured' do
    before { configure('') }

    it 'does not echo the challenge, even for an empty token' do
      handshake('')
      expect(response.body).not_to eq(challenge)
    end
  end
end
