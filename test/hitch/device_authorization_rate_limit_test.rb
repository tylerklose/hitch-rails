# frozen_string_literal: true

require "test_helper"

# The device flow's two quotas. The verification check is a term in the user
# code's brute-force math (RFC 8628 §5.1), so the posture tests here mirror
# registration's: an uncountable store admits nothing in production.
class Hitch::DeviceAuthorizationRateLimitTest < ActiveSupport::TestCase
  setup do
    @store = ActiveSupport::Cache::MemoryStore.new
    Hitch.configure do |config|
      config.device_authorization_rate_store = @store
      config.device_authorization_limit = { to: 2, within: 60 }
      config.device_code_verification_limit = { to: 3, within: 60 }
    end
    @user = User.create!(email: "limit+#{SecureRandom.hex(4)}@test")
  end

  teardown do
    User.delete_all
  end

  test "mint attempts are counted per IP up to the limit" do
    2.times { assert Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7") }

    error = assert_raises(Hitch::RateLimitStore::Exceeded) do
      Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
    end
    assert_equal 60, error.retry_after
    assert Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.8")
  end

  test "verification attempts are counted per principal, not shared" do
    other = User.create!(email: "limit-other+#{SecureRandom.hex(4)}@test")
    3.times { assert Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: @user) }

    assert_raises(Hitch::RateLimitStore::Exceeded) do
      Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: @user)
    end
    assert Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: other)
  end

  test "counting keys carry an HMAC of the identity, never the identity" do
    Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
    Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: @user)

    keys = @store.instance_variable_get(:@data).keys
    assert keys.all? { |key| key.start_with?("hitch:device:") }
    # The digest suffix is lowercase hex, so neither identity — the dotted
    # IP or the "User:<id>" actor — can appear in a key literally.
    refute keys.any? { |key| key.include?("203.0.113.7") }
    refute keys.any? { |key| key.include?("User:#{@user.id}") }
    assert keys.all? { |key| key.match?(/\Ahitch:device:(?:ip|code):[0-9a-f]{64}\z/) }
  end

  test "a principal with a nil id refuses rather than sharing one counting bucket" do
    unidentifiable = Struct.new(:id).new(nil)

    assert_raises(Hitch::RateLimitStore::Unavailable) do
      Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: unidentifiable)
    end
  end

  test "a garbled request IP refuses rather than counting everyone as one" do
    assert_raises(Hitch::RateLimitStore::Unavailable) do
      Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "not-an-ip")
    end
  end

  test "production fails closed when the store cannot count" do
    Hitch.configuration.device_authorization_rate_store = ActiveSupport::Cache::NullStore.new

    with_production do
      assert_raises(Hitch::RateLimitStore::Unavailable) do
        Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
      end
      assert_raises(Hitch::RateLimitStore::Unavailable) do
        Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: @user)
      end
    end
  end

  test "nonproduction admits when the store cannot count, as Rails does" do
    Hitch.configuration.device_authorization_rate_store = ActiveSupport::Cache::NullStore.new

    assert Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
    assert Hitch::DeviceAuthorizationRateLimit.check_verification!(principal: @user)
  end

  test "the nil default counts through the application's cache store" do
    Hitch.configuration.device_authorization_rate_store = nil

    assert_equal ActionController::Base.cache_store, Hitch.configuration.device_authorization_rate_store
    # This environment's store is Rails' :null_store, which cannot count —
    # so the adopter default admits here and refuses in production, per the
    # posture tests above. What this drives is the fallback itself.
    assert Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
  end

  test "the boot check refuses a store that cannot count across processes" do
    Hitch.configuration.device_authorization_rate_store = ActiveSupport::Cache::MemoryStore.new
    error = assert_raises(ArgumentError) do
      Hitch.configuration.validate_device_authorization_rate_store!
    end
    assert_includes error.message, "device_authorization_rate_store"

    # nil resolves this environment's :null_store — the adopter default a
    # production boot must also refuse.
    Hitch.configuration.device_authorization_rate_store = nil
    assert_raises(ArgumentError) do
      Hitch.configuration.validate_device_authorization_rate_store!
    end

    shared = Class.new(ActiveSupport::Cache::Store) do
      def increment(_name, amount = 1, **) = amount
    end.new
    Hitch.configuration.device_authorization_rate_store = shared
    assert Hitch.configuration.validate_device_authorization_rate_store!
  end

  test "a raising store refuses in every environment" do
    broken = ActiveSupport::Cache::MemoryStore.new
    def broken.increment(*, **) = raise IOError, "connection refused"
    Hitch.configuration.device_authorization_rate_store = broken

    error = assert_raises(Hitch::RateLimitStore::Unavailable) do
      Hitch::DeviceAuthorizationRateLimit.check_mint!(remote_ip: "203.0.113.7")
    end
    assert_includes error.message, "increment failed"
  end

  private

  def with_production(&block)
    production = ActiveSupport::EnvironmentInquirer.new("production")
    stub_class_method(Rails, :env, -> { production }, &block)
  end
end
