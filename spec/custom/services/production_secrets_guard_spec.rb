require 'rails_helper'

# Fork: production refuses to boot unless Rails will actually encrypt.
#
# `Chatwoot.encryption_configured?` (config/application.rb:107) gates `encrypts`
# on every Instagram / Facebook / Telegram / Twilio access token, webhook secret
# and integration hook token — but nothing ever CALLED it at boot. Start the
# fork with the keys unset and the container reports healthy, every channel
# credential is written in the clear, and no error appears anywhere. That
# already happened once: ../agentic-str/docs/troubleshooting/chatwoot-integration/
# 119-chatwoot-plaintext-channel-tokens-encryption-unconfigured.md.
#
# It is not self-healing, which is why this is a boot guard and not a warning:
# `support_unencrypted_data = true` (application.rb:86) keeps rows written
# during that window readable AND plaintext forever. Only new writes get
# encrypted, so every token from day one stays in the clear until each channel
# is reconnected by hand.
#
# The guard reads `ActiveRecord::Encryption.config` — the object `encrypts`
# actually consumes — rather than re-reading the three ENV names itself.
# application.rb assigns that config inside `if ENV[PRIMARY_KEY].present?`, so a
# primary key set WITHOUT the other two leaves a half-configured encryptor that
# a presence check on the primary key alone would wave through.
RSpec.describe Custom::ProductionSecretsGuard do
  subject(:boot) do
    described_class.run!(env: env, rails_env: rails_env, encryption_config: encryption_config)
  end

  let(:primary_key) { 'primary-key-value' }
  let(:deterministic_key) { 'deterministic-key-value' }
  let(:key_derivation_salt) { 'key-derivation-salt-value' }
  let(:secret_key_base) { 'f' * 128 }
  let(:rails_env) { 'production' }

  # `has_<key>?` and not `<key>`: the bare readers RAISE
  # `ActiveRecord::Encryption::Errors::Configuration` when the key is unset
  # (activerecord-7.2.3.1 encryption/config.rb:36-45), so a guard built on them
  # would abort with Rails' own error instead of naming the variable to set.
  # The predicates return `.presence`, which also treats a blank string as unset.
  let(:encryption_config) do
    instance_double(
      ActiveRecord::Encryption::Config,
      has_primary_key?: primary_key,
      has_deterministic_key?: deterministic_key,
      has_key_derivation_salt?: key_derivation_salt
    )
  end

  let(:env) { { 'SECRET_KEY_BASE' => secret_key_base } }

  it 'boots when all four secrets are set' do
    expect { boot }.not_to raise_error
  end

  context 'when the deterministic key is missing' do
    # The half-configured case: application.rb DID run its config block, so the
    # primary key is set and `encrypts` is live — with a nil deterministic key.
    let(:deterministic_key) { nil }

    it 'refuses to boot' do
      expect { boot }.to raise_error(described_class::MisconfiguredError)
    end

    it 'names the variable the operator has to set' do
      expect { boot }.to raise_error(/ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY/)
    end
  end

  context 'when the primary key is missing' do
    let(:primary_key) { nil }

    it 'refuses to boot' do
      expect { boot }.to raise_error(described_class::MisconfiguredError, /ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY/)
    end
  end

  context 'when the key derivation salt is missing' do
    let(:key_derivation_salt) { nil }

    it 'refuses to boot' do
      expect { boot }.to raise_error(described_class::MisconfiguredError, /ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT/)
    end
  end

  context 'when SECRET_KEY_BASE is blank' do
    # What `.env.example` ships, and what a half-filled .env on the box leaves.
    let(:secret_key_base) { '' }

    it 'refuses to boot' do
      expect { boot }.to raise_error(described_class::MisconfiguredError, /SECRET_KEY_BASE/)
    end
  end

  context 'when SECRET_KEY_BASE is still upstream placeholder text' do
    # Rails accepts any non-empty string here, so a copied placeholder boots
    # clean and signs every session with a value published on GitHub.
    let(:secret_key_base) { 'replace_with_lots_of_random_characters' }

    it 'refuses to boot' do
      expect { boot }.to raise_error(described_class::MisconfiguredError, /SECRET_KEY_BASE/)
    end
  end

  context 'when everything is missing at once' do
    let(:primary_key) { nil }
    let(:deterministic_key) { nil }
    let(:key_derivation_salt) { nil }
    let(:secret_key_base) { nil }

    it 'reports all four in one message rather than one per restart' do
      expect { boot }.to raise_error(
        described_class::MisconfiguredError,
        /SECRET_KEY_BASE.*PRIMARY_KEY.*DETERMINISTIC_KEY.*KEY_DERIVATION_SALT/m
      )
    end
  end

  context 'when assets precompile during the image build' do
    # docker/Dockerfile compiles assets with RAILS_ENV=production long before any
    # real secret exists, so a guard that only looked at RAILS_ENV would fail the
    # BUILD — the deploy would break at `docker build`, not at a misconfigured
    # boot. `SECRET_KEY_BASE_DUMMY` is Rails' own signal for this
    # (railties application.rb:467-471, and the Dockerfile it generates); the
    # fork's Dockerfile sets it for exactly this reason.
    let(:env) { { 'SECRET_KEY_BASE_DUMMY' => '1' } }
    let(:primary_key) { nil }
    let(:deterministic_key) { nil }
    let(:key_derivation_salt) { nil }

    it 'lets the build finish' do
      expect { boot }.not_to raise_error
    end
  end

  context 'when the environment is not production' do
    let(:rails_env) { 'development' }
    let(:primary_key) { nil }
    let(:deterministic_key) { nil }
    let(:key_derivation_salt) { nil }
    let(:secret_key_base) { nil }

    # Local dev and CI run without these by design; doctor.sh covers the dev
    # box. A guard that stopped development boots would simply be turned off.
    it 'stays out of the way' do
      expect { boot }.not_to raise_error
    end
  end

  describe 'default wiring' do
    # Pin the guard to the mechanism, not to a second copy of the ENV names:
    # whatever `encrypts` consumes is what gets checked.
    it 'reads the encryption config Rails will actually use' do
      allow(ActiveRecord::Encryption).to receive(:config).and_return(encryption_config)
      allow(encryption_config).to receive(:has_deterministic_key?).and_return(nil)

      expect { described_class.run!(env: env, rails_env: 'production') }
        .to raise_error(described_class::MisconfiguredError, /DETERMINISTIC_KEY/)
    end
  end
end
