# Messenger webhook subscription handshake (GET /bot).
#
# Meta sends `hub.verify_token`; the handshake succeeds only when it equals the
# installation's FB_VERIFY_TOKEN. Compared in constant time. An unset
# FB_VERIFY_TOKEN rejects every handshake instead of matching an empty token.
#
# Prepended onto ChatwootFbProvider (config/initializers/facebook_messenger.rb)
# from config/initializers/custom_prepends.rb, so the upstream file is not
# edited. Spec: spec/custom/initializers/facebook_messenger_verify_token_spec.rb.
#
# Compact module form for the same namespace reason as the sibling
# `Custom::PrependOnce` — see docs/fork/UPSTREAM_DIFF.md §2.
module Custom::FacebookMessengerVerifyToken
  def valid_verify_token?(verify_token)
    expected = GlobalConfigService.load('FB_VERIFY_TOKEN', '').to_s
    return false if expected.empty? || verify_token.to_s.empty?

    ActiveSupport::SecurityUtils.secure_compare(verify_token.to_s, expected)
  end
end
