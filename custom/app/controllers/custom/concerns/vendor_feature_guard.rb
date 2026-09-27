# Controller half of Custom::VendorFeaturePolicy: refuse a platform-owned
# feature to anyone who is not the platform's own service identity.
#
# 403 (not 404): the request is well-formed and the resource may exist; this
# account is simply not allowed to manage it here. `error_code` lets a client
# tell this apart from upstream's own authorization failures.
module Custom::Concerns::VendorFeatureGuard
  private

  def refuse_platform_managed_feature
    render json: {
      error: I18n.t('errors.vendor_feature_policy.managed_by_platform'),
      error_code: Custom::VendorFeaturePolicy::ERROR_CODE
    }, status: :forbidden
  end
end
