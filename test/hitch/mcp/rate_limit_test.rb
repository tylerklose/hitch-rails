# frozen_string_literal: true

require "test_helper"
require "json"
require "openssl"
require "securerandom"
require "tmpdir"

class Hitch::MCP::RateLimitTest < ActiveSupport::TestCase
  RATE_LIMIT_KEY = Hitch::MCP.const_get(:RateLimitKey, false)

  class KeyGenerator
    attr_reader :calls

    def initialize(secret)
      @secret = secret
      @calls = []
    end

    def generate_key(salt, length)
      calls << [ salt, length ]
      @secret
    end
  end
  private_constant :KeyGenerator

  setup do
    Hitch.reset_configuration!
    @user = User.create!(email: "rate-key-#{SecureRandom.hex(4)}@example.test")
  end

  teardown do
    Hitch.reset_configuration!
    @user&.destroy!
  end

  test "HMAC key is canonical, token independent, and separated by principal and client" do
    first_generator = KeyGenerator.new("a" * 32)
    rotated_generator = KeyGenerator.new("b" * 32)
    canonical = JSON.generate([ "User", @user.id.to_s, "client-one" ])
    expected = "hitch:mcp:rate-limit:v1:" +
      OpenSSL::HMAC.hexdigest("SHA256", "a" * 32, canonical)

    first = RATE_LIMIT_KEY.call(
      principal: @user,
      client_id: "client-one",
      key_generator: first_generator
    )
    second_client = RATE_LIMIT_KEY.call(
      principal: @user,
      client_id: "client-two",
      key_generator: first_generator
    )
    second_user = User.create!(email: "rate-key-other-#{SecureRandom.hex(4)}@example.test")
    second_principal = RATE_LIMIT_KEY.call(
      principal: second_user,
      client_id: "client-one",
      key_generator: first_generator
    )
    rotated = RATE_LIMIT_KEY.call(
      principal: @user,
      client_id: "client-one",
      key_generator: rotated_generator
    )

    assert_equal expected, first
    assert_equal [ [ "hitch/mcp/rate-limit/v1", 32 ] ], rotated_generator.calls
    refute_equal first, second_client
    refute_equal first, second_principal
    refute_equal first, rotated
    refute_includes first, "client-one"
  ensure
    second_user&.destroy!
  end

  test "the configured store defaults to the application controller cache store" do
    configuration = Hitch::MCP::Configuration.new

    assert_same ActionController::Base.cache_store, configuration.rate_limit_store
  end

  test "an explicit store is used verbatim and nil falls back" do
    store = ActiveSupport::Cache::MemoryStore.new
    configuration = Hitch::MCP::Configuration.new
    configuration.rate_limit_store = store

    assert_same store, configuration.rate_limit_store

    configuration.rate_limit_store = nil
    assert_same ActionController::Base.cache_store, configuration.rate_limit_store
  end

  test "a store that cannot increment is rejected at assignment" do
    configuration = Hitch::MCP::Configuration.new

    error = assert_raises(ArgumentError) { configuration.rate_limit_store = Object.new }
    assert_includes error.message, "mcp.rate_limit_store"
  end

  test "production refuses a store that cannot count across processes" do
    unshared = [
      ActiveSupport::Cache::MemoryStore.new,
      ActiveSupport::Cache::NullStore.new,
      ActiveSupport::Cache::FileStore.new(Dir.mktmpdir)
    ]

    unshared.each do |store|
      configuration = configured_runtime(to: 2, within: 60, store:)

      assert configuration.validate_rate_limit_store!,
        "#{store.class.name} is allowed outside production"

      in_production do
        error = assert_raises(ArgumentError, store.class.name) do
          configuration.validate_rate_limit_store!
        end
        assert_includes error.message, "cannot count one"
        assert_includes error.message, store.class.name
      end
    end
  end

  test "production accepts a store that counts across processes" do
    shared = Class.new(ActiveSupport::Cache::Store) do
      def increment(name, amount = 1, **options) = 1
    end.new
    configuration = configured_runtime(to: 2, within: 60, store: shared)

    in_production { assert configuration.validate_rate_limit_store! }
  end

  test "validate! no longer demands a store, so a Solid Cache app boots in production" do
    configuration = configured_runtime(to: 120, within: 60, store: nil)

    in_production { assert configuration.validate! }
  end

  test "rate implementation constants are not public extension points" do
    assert_raises(NameError) { eval("Hitch::MCP::RateLimitKey") }
  end

  test "the removed private store classes are gone entirely" do
    %i[RedisRateStore MemoryRateStore RequestRateLimiter].each do |name|
      refute Hitch::MCP.const_defined?(name, false), "Hitch::MCP::#{name} still exists"
    end
  end

  private

  def configured_runtime(to:, within:, store: nil)
    Hitch::MCP::Configuration.new.tap do |configuration|
      configuration.registry = "McpToolRegistry"
      configuration.server_info = { name: "rate-test", version: "0.2.0" }
      configuration.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.request_limit = { to:, within: }
      configuration.rate_limit_store = store
    end
  end

  def in_production
    original = Rails.env
    Rails.env = "production"
    yield
  ensure
    Rails.env = original.to_s
  end
end
