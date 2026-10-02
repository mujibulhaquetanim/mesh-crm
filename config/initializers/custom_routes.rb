# Fork routes, drawn from a fork-only file so config/routes.rb stays upstream's.
#
# `prepend` puts these ahead of everything in config/routes.rb, so a path that
# upstream also defines (the enterprise limits endpoint, when an enterprise
# folder is present in development) is served by the fork's controller in every
# build. Production runs without `enterprise/`, where
# upstream does not draw the path at all.
Rails.application.routes.prepend do
  get 'enterprise/api/v1/accounts/:account_id/limits',
      to: 'custom/account_limits#show',
      defaults: { format: 'json' },
      as: :custom_account_limits
end
