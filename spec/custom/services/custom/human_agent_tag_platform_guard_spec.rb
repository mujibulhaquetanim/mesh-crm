require 'rails_helper'

# Meta allows the HUMAN_AGENT tag only on replies a person wrote. Upstream decides
# "a person wrote it" with `sender.is_a?(User)`, which is also true for the
# platform-managed users provisioning creates (the AI reply identity is one). These
# specs pin that a platform-managed sender never gets the tag, on either channel,
# while an ordinary agent still does.
RSpec.describe Custom::HumanAgentTagPlatformGuard do
  let!(:account) { create(:account) }
  let(:human_agent) { create(:user, account: account) }
  let(:platform_user) do
    create(:user, account: account).tap do |user|
      AccountUser.find_by!(account: account, user: user).update!(platform_managed: true)
    end
  end

  it 'is prepended onto both send services that include the upstream helper' do
    expect(Facebook::SendOnFacebookService.ancestors).to include(described_class)
    expect(Instagram::BaseSendService.ancestors).to include(described_class)
  end

  describe 'on Messenger' do
    # Declared before the `let!`s below: creating the channel subscribes the Page,
    # so the stub has to be in place first.
    before do
      allow(Facebook::Messenger::Subscriptions).to receive(:subscribe).and_return(true)
      allow(bot).to receive(:deliver).and_return({ recipient_id: '1', message_id: 'mid.1' }.to_json)
      create(:message, message_type: :incoming, inbox: facebook_inbox, account: account, conversation: conversation)
      GlobalConfig.clear_cache
    end

    let(:bot) { class_double(Facebook::Messenger::Bot).as_stubbed_const }
    let!(:facebook_channel) { create(:channel_facebook_page, account: account) }
    let!(:facebook_inbox) { create(:inbox, channel: facebook_channel, account: account) }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: facebook_inbox) }
    let(:conversation) { create(:conversation, contact: contact, inbox: facebook_inbox, contact_inbox: contact_inbox) }

    around do |example|
      with_modified_env(ENABLE_MESSENGER_CHANNEL_HUMAN_AGENT: 'true') { example.run }
    end

    def send_after_window(sender)
      travel_to(25.hours.from_now) do
        message = create(:message, message_type: 'outgoing', sender: sender,
                                   inbox: facebook_inbox, account: account, conversation: conversation)
        Facebook::SendOnFacebookService.new(message: message).perform
      end
    end

    it 'does not tag a platform-managed sender after the 24-hour window' do
      send_after_window(platform_user)

      expect(bot).to have_received(:deliver).with(hash_including(messaging_type: 'RESPONSE'), { page_id: facebook_channel.page_id })
      expect(bot).not_to have_received(:deliver).with(hash_including(:tag), anything)
    end

    it 'still tags an ordinary agent after the 24-hour window' do
      send_after_window(human_agent)

      expect(bot).to have_received(:deliver).with(
        hash_including(messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT'),
        { page_id: facebook_channel.page_id }
      )
    end
  end

  describe 'on Instagram' do
    let!(:instagram_channel) { create(:channel_instagram, account: account, instagram_id: 'instagram-message-id-123') }
    let!(:instagram_inbox) { create(:inbox, channel: instagram_channel, account: account, greeting_enabled: false) }
    let(:contact) { create(:contact, account: account) }
    let(:contact_inbox) { create(:contact_inbox, contact: contact, inbox: instagram_inbox) }
    let(:conversation) { create(:conversation, contact: contact, inbox: instagram_inbox, contact_inbox: contact_inbox) }
    let(:ok_response) do
      instance_double(
        HTTParty::Response,
        :success? => true,
        :body => { message_id: 'random_message_id' }.to_json,
        :parsed_response => { 'message_id' => 'random_message_id' }
      )
    end

    before do
      allow(HTTParty).to receive(:post).and_return(ok_response)
      InstallationConfig.where(name: 'ENABLE_INSTAGRAM_CHANNEL_HUMAN_AGENT').first_or_create(value: true)
      GlobalConfig.clear_cache
      create(:message, message_type: :incoming, inbox: instagram_inbox, account: account, conversation: conversation)
    end

    def send_after_window(sender)
      travel_to(25.hours.from_now) do
        message = create(:message, message_type: 'outgoing', sender: sender,
                                   inbox: instagram_inbox, account: account, conversation: conversation)
        Instagram::SendOnInstagramService.new(message: message).perform
      end
    end

    it 'does not tag a platform-managed sender after the 24-hour window' do
      send_after_window(platform_user)

      expect(HTTParty).to have_received(:post)
      expect(HTTParty).not_to have_received(:post).with(anything, hash_including(body: hash_including(:tag)))
    end

    it 'still tags an ordinary agent after the 24-hour window' do
      send_after_window(human_agent)

      expect(HTTParty).to have_received(:post).with(
        anything, hash_including(body: hash_including(messaging_type: 'MESSAGE_TAG', tag: 'HUMAN_AGENT'))
      )
    end
  end
end
