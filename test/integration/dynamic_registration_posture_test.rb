# frozen_string_literal: true

require "test_helper"

class DynamicRegistrationPostureTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "https://client.example/callback"

  # Stands in for a shared production store: an ordinary cache store that
  # counts, recording what admission asked of it.
  class RecordingStore < ActiveSupport::Cache::MemoryStore
    attr_reader :calls

    def initialize(*arguments)
      super
      @calls = []
    end

    def increment(name, amount = 1, **options)
      @calls << { key: name, expires_in: options[:expires_in] }
      super
    end
  end

  class BrokenStore < ActiveSupport::Cache::MemoryStore
    def increment(*, **)
      raise "backend secret-shaped failure"
    end
  end

  class GarbageStore < ActiveSupport::Cache::MemoryStore
    def increment(*, **) = "not a count"
  end

  setup do
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = "https://auth.example/mcp"
      config.allowed_hosts = [ "www.example.com" ]
      config.dynamic_client_registration_enabled = true
    end
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "disabled DCR is omitted from metadata and returns stable not found" do
    Hitch.configuration.dynamic_client_registration_enabled = false

    get "/.well-known/oauth-authorization-server"
    assert_response :success
    refute JSON.parse(response.body).key?("registration_endpoint")

    post_registration
    assert_response :not_found
    assert_empty response.body
    assert_equal 0, Hitch::Client.count
  end

  test "library fallback remains enabled for an existing non-production install" do
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = "https://auth.example/mcp"
      config.allowed_hosts = [ "www.example.com" ]
    end

    assert Hitch.configuration.dynamic_client_registration_enabled
    refute Hitch.configuration.dynamic_client_registration_enabled_configured?

    post_registration
    assert_response :created
  end

  test "one increment against the host cache store supplies the post-increment count" do
    store = RecordingStore.new
    Hitch.configure do |config|
      config.dynamic_client_registration_rate_store = store
      config.dynamic_client_registration_limit = { to: 2, within: 45 }
    end

    2.times do
      post_registration
      assert_response :created
    end

    post_registration
    assert_response :too_many_requests
    assert_equal "45", response.headers["Retry-After"]
    assert_equal "temporarily_unavailable", JSON.parse(response.body).fetch("error")
    assert_equal 2, Hitch::Client.count
    assert_equal 3, store.calls.length
    assert store.calls.all? { |call| call.fetch(:expires_in) == 45 }
    refute store.calls.any? { |call| call.fetch(:key).include?("127.0.0.1") }
  end

  # Registration is unauthenticated, so a store that cannot count refuses in
  # production rather than admitting. MCP request admission, which sits behind
  # a bearer token, deliberately admits instead.
  test "production fails closed when the store cannot count" do
    Hitch.configuration.dynamic_client_registration_rate_store = ActiveSupport::Cache::NullStore.new

    with_production { post_registration }

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
  end

  test "nonproduction admits when the store cannot count, as Rails does" do
    Hitch.configuration.dynamic_client_registration_rate_store = ActiveSupport::Cache::NullStore.new

    post_registration

    assert_response :created
  end

  test "a store that cannot increment is rejected at assignment" do
    error = assert_raises(ArgumentError) do
      Hitch.configuration.dynamic_client_registration_rate_store = Object.new
    end

    assert_includes error.message, "config.dynamic_client_registration_rate_store"
  end

  test "a store that never overrode increment makes registration unavailable" do
    # Base ActiveSupport::Cache::Store#increment raises NotImplementedError, a
    # ScriptError; registration must still degrade to its designed 503.
    Hitch.configuration.dynamic_client_registration_rate_store =
      ActiveSupport::Cache::Store.new

    post_registration

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
  end

  test "production boot refuses a nil store outright" do
    error = assert_raises(ArgumentError) do
      Hitch::RateLimitStore.assert_shared!(
        nil, setting: Hitch::DynamicRegistrationRateLimit::SETTING
      )
    end

    assert_includes error.message, "must be an ActiveSupport::Cache store"
  end

  test "production boot rejects a store that cannot count across processes" do
    [ ActiveSupport::Cache::MemoryStore.new, ActiveSupport::Cache::NullStore.new ].each do |store|
      error = assert_raises(ArgumentError, store.class.name) do
        Hitch::RateLimitStore.assert_shared!(
          store, setting: Hitch::DynamicRegistrationRateLimit::SETTING
        )
      end
      assert_includes error.message, "cannot count one caller's"
    end
  end

  test "store errors fail closed without leaking backend details" do
    Hitch.configuration.dynamic_client_registration_rate_store = BrokenStore.new

    post_registration

    assert_response :service_unavailable
    assert_equal "temporarily_unavailable", JSON.parse(response.body).fetch("error")
    refute_includes response.body, "secret-shaped"
    assert_equal 0, Hitch::Client.count
  end

  test "an invalid store return fails closed" do
    Hitch.configuration.dynamic_client_registration_rate_store = GarbageStore.new

    post_registration

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
  end

  private

  def post_registration
    post "/oauth/register", params: {
      client_name: "Test Client",
      redirect_uris: [ REDIRECT_URI ]
    }, as: :json
  end

  def with_production(&block)
    production = ActiveSupport::EnvironmentInquirer.new("production")
    stub_class_method(Rails, :env, -> { production }, &block)
  end
end
