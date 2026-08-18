require 'rails_helper'

# Verifies the view-path shadow (custom/app/views/super_admin/devise/sessions/new.html.erb)
# actually renders the otp_attempt field the flag-gated controller override
# (custom/app/controllers/custom/super_admin/devise/sessions_controller.rb)
# depends on. This is the ONLY way an operator supplies a code, so if
# custom/app/views precedence ever regresses (config/application.rb), the
# form silently loses this input while enforcement stays on — every enrolled
# operator locked out with no other failing test to catch it.
#
# GET /super_admin/sign_in 500s in this test environment (pre-existing,
# unrelated Vite/asset-manifest issue — see docs/fork/error-log and the
# "renders the login page" failure already excluded elsewhere). So this
# asserts at the template-render level instead of the request level, and
# stubs the vite_* helpers purely to isolate this template from that
# unrelated infra issue — it does not touch or fix it.
RSpec.describe 'super_admin/devise/sessions/new', type: :view do
  before do
    # `resource`/`resource_name` are Devise helper_methods that only exist on
    # a real Devise-mapped controller, not on the bare ActionView::TestCase
    # controller this harness uses — RSpec's verifying partial doubles
    # (`allow(view).to receive(:resource)`) refuse to stub a method the
    # class doesn't already define, so these are defined directly instead.
    view.define_singleton_method(:resource) { SuperAdmin.new }
    view.define_singleton_method(:resource_name) { :super_admin }
    view.define_singleton_method(:vite_client_tag) { '' }
    view.define_singleton_method(:vite_javascript_tag) { |*| '' }
  end

  it 'renders the otp_attempt field when SUPER_ADMIN_ENFORCE_MFA is on' do
    with_modified_env(SUPER_ADMIN_ENFORCE_MFA: 'true') { render }
    expect(rendered).to include('super_admin[otp_attempt]')
  end

  it 'omits the otp_attempt field when SUPER_ADMIN_ENFORCE_MFA is off (default)' do
    render
    expect(rendered).not_to include('super_admin[otp_attempt]')
  end
end
