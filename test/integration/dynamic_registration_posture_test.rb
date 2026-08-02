# frozen_string_literal: true

require "test_helper"

class DynamicRegistrationPostureTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "https://client.example/callback"

  class AtomicStore
    attr_reader :calls

    def initialize
      @calls = []
      @counts = Hash.new(0)
      @mutex = Mutex.new
    end

    def shared?
      true
    end

    def increment_with_expiry(key:, expires_in:)
      @mutex.synchronize do
        @calls << { key: key, expires_in: expires_in }
        @counts[key] += 1
      end
    end
  end

  class BrokenStore
    def shared?
      true
    end

    def increment_with_expiry(**)
      raise "backend secret-shaped failure"
    end
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

  test "one atomic increment-with-expiry operation supplies the post-increment count" do
    store = AtomicStore.new
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

  test "production fails closed when the shared store is missing" do
    with_production do
      post_registration
    end

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
  end

  test "production fails closed when the configured store cannot prove the contract" do
    Hitch.configuration.dynamic_client_registration_rate_store = Object.new

    with_production do
      post_registration
    end

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
  end

  test "production rejects a process-local store" do
    store = AtomicStore.new
    store.define_singleton_method(:shared?) { false }
    Hitch.configuration.dynamic_client_registration_rate_store = store

    with_production do
      post_registration
    end

    assert_response :service_unavailable
    assert_equal 0, Hitch::Client.count
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
    store = AtomicStore.new
    store.define_singleton_method(:increment_with_expiry) { |**| nil }
    Hitch.configuration.dynamic_client_registration_rate_store = store

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
