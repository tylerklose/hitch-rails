# frozen_string_literal: true

require "test_helper"
require "json"
require "openssl"

class Hitch::MCP::RateLimitTest < ActiveSupport::TestCase
  REDIS_STORE = Hitch::MCP.const_get(:RedisRateStore, false)
  MEMORY_STORE = Hitch::MCP.const_get(:MemoryRateStore, false)
  RATE_LIMIT_KEY = Hitch::MCP.const_get(:RateLimitKey, false)
  REQUEST_RATE_LIMITER = Hitch::MCP.const_get(:RequestRateLimiter, false)

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

  class RedisClient
    attr_accessor :response
    attr_reader :calls, :closed

    def initialize(response)
      @response = response
      @calls = []
      @closed = false
    end

    def eval(*arguments)
      calls << arguments
      response
    end

    def close
      @closed = true
    end
  end
  private_constant :RedisClient

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

  test "memory store preserves first expiry and resets only after the window" do
    now = 10.0
    store = MEMORY_STORE.new(clock: -> { now })

    assert_equal [ 1, 1_000 ], store.increment(key: "key", window_ms: 1_000)
    now = 10.4
    assert_equal [ 2, 600 ], store.increment(key: "key", window_ms: 1_000)
    now = 10.9
    assert_equal [ 3, 100 ], store.increment(key: "key", window_ms: 20_000)
    now = 11.0
    assert_equal [ 1, 20_000 ], store.increment(key: "key", window_ms: 20_000)
  end

  test "memory store increment is exact under simultaneous callers" do
    store = MEMORY_STORE.new(clock: -> { 10.0 })
    gate = Queue.new
    threads = 24.times.map do
      Thread.new do
        gate.pop
        store.increment(key: "shared", window_ms: 60_000).first
      end
    end
    24.times { gate << true }

    assert_equal (1..24).to_a, threads.map(&:value).sort
  ensure
    threads&.each { |thread| thread.join if thread.alive? }
  end

  test "Redis store uses one Lua increment and first-expiry call" do
    client = RedisClient.new([ 1, 60_000 ])
    store = REDIS_STORE.new(url: "redis://unused.example.test/0", client:)

    assert_equal [ 1, 60_000 ], store.increment(key: "synthetic-digest", window_ms: 60_000)
    assert_equal 1, client.calls.length
    script, keys, arguments = client.calls.fetch(0)
    assert_match(/redis\.call\("INCR", KEYS\[1\]\)/, script)
    assert_match(/if count == 1/, script)
    assert_match(/redis\.call\("PEXPIRE", KEYS\[1\], ARGV\[1\]\)/, script)
    assert_equal [ "synthetic-digest" ], keys
    assert_equal [ 60_000 ], arguments

    store.close
    assert client.closed
  end

  test "Redis store rejects nil, malformed, and missing-expiry responses" do
    client = RedisClient.new(nil)
    store = REDIS_STORE.new(url: "redis://unused.example.test/0", client:)

    [ nil, [ 1 ], [ "1", 60_000 ], [ 0, 60_000 ], [ 1, -1 ] ].each do |response|
      client.response = response
      assert_raises(ArgumentError, response.inspect) do
        store.increment(key: "synthetic-digest", window_ms: 60_000)
      end
    end
  end

  test "request limiter holds the inclusive boundary and does not reset on limit changes" do
    configuration = configured_runtime(to: 2, within: 60)

    assert_equal :allow, REQUEST_RATE_LIMITER.call(
      principal: @user,
      client_id: "client-one",
      configuration:
    )
    assert_equal :allow, REQUEST_RATE_LIMITER.call(
      principal: @user,
      client_id: "client-one",
      configuration:
    )
    configuration.request_limit = { to: 3, within: 120 }
    assert_equal :allow, REQUEST_RATE_LIMITER.call(
      principal: @user,
      client_id: "client-one",
      configuration:
    )
    assert_equal({ retry_after: 120 }, REQUEST_RATE_LIMITER.call(
      principal: @user,
      client_id: "client-one",
      configuration:
    ))
  end

  test "rate store connection is reused across limit changes and replaced after URL reload" do
    configuration = configured_runtime(to: 2, within: 60)
    memory = configuration.__send__(:rate_store!)
    configuration.request_limit = { to: 5, within: 120 }
    configuration.__send__(:prepare_rate_store!)
    assert_same memory, configuration.__send__(:rate_store!)

    configuration.rate_limit_redis_url = "redis://127.0.0.1:1/0"
    configuration.__send__(:prepare_rate_store!)
    first_redis = configuration.__send__(:rate_store!)
    configuration.rate_limit_redis_url = "redis://127.0.0.1:1/0"
    configuration.__send__(:prepare_rate_store!)

    assert_instance_of REDIS_STORE, first_redis
    assert_instance_of REDIS_STORE, configuration.__send__(:rate_store!)
    refute_same first_redis, configuration.__send__(:rate_store!)
  end

  test "rate implementation constants are not public extension points" do
    %i[RateLimitKey RedisRateStore MemoryRateStore RequestRateLimiter].each do |name|
      assert_raises(NameError) { eval("Hitch::MCP::#{name}") }
    end
  end

  private

  def configured_runtime(to:, within:)
    Hitch::MCP::Configuration.new.tap do |configuration|
      configuration.registry = "McpToolRegistry"
      configuration.server_info = ->(_context) { { name: "rate-test", version: "0.2.0" } }
      configuration.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.request_limit = { to:, within: }
      configuration.__send__(:prepare_rate_store!)
    end
  end
end
