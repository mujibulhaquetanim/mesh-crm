# Fork: production refuses to boot unless Rails will actually encrypt.
# Reasoning, and what losing these keys costs, lives next to the check in
# custom/app/services/custom/production_secrets_guard.rb.
#
# `after_initialize` rather than a bare call at load time, for two reasons:
#
# 1. `ActiveRecord::Encryption.config` is populated by a lazy
#    `ActiveSupport.on_load(:active_record_encryption)` hook that activerecord's
#    railtie registers. Reading it from an initializer body can see a Config
#    that nothing has filled in yet, which would fail for the wrong reason.
# 2. `Custom::ProductionSecretsGuard` is autoloaded out of `custom/app/**`;
#    referencing an autoloaded constant while initializers run is exactly what
#    Zeitwerk objects to.
#
# It runs for every process that loads the environment — puma, Sidekiq, and
# `rails db:chatwoot_prepare` — which is deliberate: `prepare` is the step that
# first writes to a fresh database, and catching it there is better than
# catching it after.
Rails.application.config.after_initialize do
  Custom::ProductionSecretsGuard.run!
end
