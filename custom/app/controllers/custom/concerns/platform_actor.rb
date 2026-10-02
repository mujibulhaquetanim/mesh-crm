# Verified service-identity check for the platform-managed exemption.
#
# `platform_managed` marks control-plane infrastructure (the AI reply user, the
# orchestrator-ingest account webhook, the automation account_user) so it is
# excluded from tenant entitlement counts. That exemption must be grantable ONLY
# by the control plane — never by a tenant-supplied request flag.
#
# The trust signal is already persisted and cannot be forged from a request: the
# control plane's own service user is itself a `platform_managed` account_user,
# while every vendor identity is `platform_managed: false`. So we key the
# exemption off the *acting identity*, not off params. Vendors are account
# administrators, but never platform-managed, so they can never self-grant the
# exemption.
module Custom::Concerns::PlatformActor
  private

  def platform_actor?
    Current.account_user&.platform_managed?
  end
end
