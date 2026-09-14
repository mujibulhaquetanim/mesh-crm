# Production refuses to boot unless Rails will actually encrypt.
#
# `Chatwoot.encryption_configured?` (config/application.rb:107) gates `encrypts`
# on every Instagram / Facebook / Telegram / Twilio access token, webhook secret
# and integration hook token — but until this guard nothing CALLED it at boot.
# Start the fork with the keys unset and the container reports healthy, every
# channel credential is written in the clear, and no error appears anywhere.
# That already happened once (docs/fork/error-log, and the platform's
# troubleshooting/119).
#
# It is a boot guard rather than a warning because the damage is not reversible
# by fixing the config afterwards: `support_unencrypted_data = true`
# (application.rb:86) keeps rows written during that window readable AND
# plaintext forever. Only new writes get encrypted, so every token from day one
# stays in the clear until each channel is reconnected by hand.
#
# It reads `ActiveRecord::Encryption.config` — the object `encrypts` actually
# consumes — rather than re-reading the three ENV names itself. application.rb
# assigns that config inside `if ENV[PRIMARY_KEY].present?`, so a primary key set
# WITHOUT the other two leaves a half-configured encryptor that a presence check
# on the ENV names alone would wave through.
module Custom
  class ProductionSecretsGuard
    MisconfiguredError = Class.new(StandardError)

    # The ENV name an operator sets => the predicate on ActiveRecord::Encryption.config
    # that reports whether it actually reached the encryptor.
    #
    # `has_<key>?` and not `<key>`: the bare readers RAISE
    # `ActiveRecord::Encryption::Errors::Configuration` when unset
    # (activerecord encryption/config.rb), which would abort with Rails' own
    # error instead of naming the variable to set. The predicates return
    # `.presence`, so a blank string counts as unset too.
    ENCRYPTION_KEYS = {
      'ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY' => :has_primary_key?,
      'ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY' => :has_deterministic_key?,
      'ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT' => :has_key_derivation_salt?
    }.freeze

    # Upstream's .env.example ships this prefix; Rails accepts any non-empty
    # string as SECRET_KEY_BASE, so a copied placeholder boots clean and signs
    # every session with a value published on GitHub.
    PLACEHOLDER_PREFIX = 'replace_with'.freeze

    def self.run!(env: ENV, rails_env: Rails.env, encryption_config: ActiveRecord::Encryption.config)
      new(env: env, rails_env: rails_env, encryption_config: encryption_config).run!
    end

    def initialize(env:, rails_env:, encryption_config:)
      @env = env
      @rails_env = rails_env
      @encryption_config = encryption_config
    end

    def run!
      return unless applies?

      missing = missing_secrets
      return if missing.empty?

      raise MisconfiguredError, message_for(missing)
    end

    private

    attr_reader :env, :rails_env, :encryption_config

    # docker/Dockerfile compiles assets with RAILS_ENV=production long before any
    # real secret exists. `SECRET_KEY_BASE_DUMMY` is Rails' own signal for that
    # build-time load (railties application.rb, and the Dockerfile Rails
    # generates); without this the guard would fail `docker build` rather than a
    # misconfigured boot.
    def applies?
      rails_env.to_s == 'production' && env['SECRET_KEY_BASE_DUMMY'].blank?
    end

    def missing_secrets
      missing = []
      missing << 'SECRET_KEY_BASE' if secret_key_base_missing?
      ENCRYPTION_KEYS.each do |name, reached_the_encryptor|
        missing << name unless encryption_config.public_send(reached_the_encryptor)
      end
      missing
    end

    def secret_key_base_missing?
      value = env['SECRET_KEY_BASE']
      value.blank? || value.start_with?(PLACEHOLDER_PREFIX)
    end

    def message_for(missing)
      <<~MESSAGE
        Refusing to boot: #{missing.size} required production secret(s) are unset or still placeholder text.

        #{missing.map { |name| "  - #{name}" }.join("\n")}

        Generate them:
          SECRET_KEY_BASE                 openssl rand -hex 64
          ACTIVE_RECORD_ENCRYPTION_*      bundle exec rails db:encryption:init   (emits all three)

        The three ACTIVE_RECORD_ENCRYPTION_* keys are required together, and unset
        means PLAINTEXT rather than an error: they gate `encrypts` on every channel
        access token, webhook secret and integration hook token.

        Booting without them is NOT fixed by adding them later. support_unencrypted_data
        is on, so anything written meanwhile stays plaintext until each channel is
        reconnected by hand. Set them before the first boot, and escrow them — they are
        as unrecoverable as the platform's ENCRYPTION_KEY.
      MESSAGE
    end
  end
end
