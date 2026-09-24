require 'rails_helper'

# custom/app/controllers/custom/dashboard_controller.rb
#
# Exercises `app_config` directly rather than GET /app/login: rendering the page
# needs the Vite build, which the rspec container cannot produce (upstream's own
# spec/controllers/dashboard_controller_spec.rb 500s there for the same reason).
# `vueapp.html.erb` renders `isEnterprise: '<%= IS_ENTERPRISE %>'` verbatim, so
# the hash value IS what the frontend receives.
RSpec.describe 'DashboardController (fork IS_ENTERPRISE on the community plan)' do
  let(:app_config) { DashboardController.new.send(:app_config) }

  before { allow(ChatwootApp).to receive(:enterprise?).and_return(true) }

  it 'is prepended onto DashboardController' do
    expect(DashboardController.ancestors).to include(Custom::DashboardController)
  end

  it 'reports IS_ENTERPRISE=false on the community plan' do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('community')

    expect(app_config[:IS_ENTERPRISE]).to be(false)
  end

  it 'keeps every other key upstream sets' do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('community')

    expect(app_config.keys).to include(:APP_VERSION, :FB_APP_ID, :INSTAGRAM_APP_ID, :ALLOWED_LOGIN_METHODS)
  end

  it 'leaves a licensed plan untouched' do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('enterprise')

    expect(app_config[:IS_ENTERPRISE]).to be(true)
  end

  it 'leaves Chatwoot Cloud untouched' do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
    allow(ChatwootApp).to receive(:chatwoot_cloud?).and_return(true)

    expect(app_config[:IS_ENTERPRISE]).to be(true)
  end

  it 'does not switch the enterprise backend off' do
    allow(ChatwootHub).to receive(:pricing_plan).and_return('community')
    app_config

    expect(ChatwootApp.enterprise?).to be(true)
  end
end
