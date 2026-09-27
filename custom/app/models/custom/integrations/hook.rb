module Custom::Integrations::Hook
  def self.prepended(base)
    base.include Custom::Concerns::QuotaGuard
  end

  # A blocked AI integration (Custom::VendorFeaturePolicy) counts as disabled
  # whatever its stored status, so a hook created before the policy stops
  # firing: HookListener and HookJob both skip `disabled?` hooks. The row is
  # left alone, so the vendor can still see and delete it.
  def disabled?
    super || Custom::VendorFeaturePolicy.blocked_integration_app?(app_id)
  end
end
