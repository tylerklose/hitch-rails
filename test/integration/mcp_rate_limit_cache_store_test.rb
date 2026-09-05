# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"
require_relative "../support/mcp_wire_admission_support"

# M4.3 erratum acceptance.
#
# Hitch admits authenticated MCP requests through the host application's own
# ActiveSupport::Cache store, exactly as Rails' ActionController::RateLimiting
# does. Redis remains one supported backend; it is never a required service and
# never a runtime gem dependency. A Solid Cache application must install Hitch
# and reach production without introducing Redis.
class MCPRateLimitCacheStoreTest < ActionDispatch::IntegrationTest
  include McpWireAdmissionSupport
  RESOURCE = "https://dummy.test/mcp"
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path

  # Records every admission write so the tests can prove which store the
  # endpoint reached, not merely that some counter advanced.
  class RecordingCacheStore < ActiveSupport::Cache::MemoryStore
    attr_reader :increments

    def initialize(*arguments)
      super
      @increments = []
    end

    def increment(name, amount = 1, **options)
      @increments << { name: name, amount: amount, expires_in: options[:expires_in] }
      super
    end
  end

  # A store that cannot count. Admission must fail closed rather than admit.
  class BrokenCacheStore < ActiveSupport::Cache::MemoryStore
    def increment(*, **)
      raise Errno::ECONNREFUSED, "cache backend unavailable"
    end
  end

  # The nil that RedisCacheStore and Solid Cache return when their backend is
  # down (their failsafe swallows the error), and that :null_store always
  # returns.
  class OutageNilStore < ActiveSupport::Cache::Store
    def increment(_name, _amount = 1, **) = nil
  end

  # A store whose increment returns something no comparison can use.
  class GarbageCountStore < ActiveSupport::Cache::Store
    def increment(_name, _amount = 1, **) = "not-a-count"
  end

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    McpController.wire_slice_enabled = true

    @application_cache = RecordingCacheStore.new
    @original_controller_cache = ActionController::Base.cache_store
    ActionController::Base.cache_store = @application_cache

    configure_runtime(to: 3, within: 60)
    @user = User.create!(email: "cache-rate@example.test")
    @token = mint_token(@user, client_id: "shared-client")
    McpController.reset_wire_metrics!
  end

  teardown do
    ActionController::Base.cache_store = @original_controller_cache
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
  end

  test "admission counts through the host application cache store by default" do
    3.times do
      post_admitted_mcp(method: "tools/list", token: @token)
      assert_response :ok
    end

    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :too_many_requests
    assert_equal "60", response.headers.fetch("Retry-After")
    assert_includes response.headers.fetch("Access-Control-Expose-Headers"), "Retry-After"

    assert_equal 4, @application_cache.increments.length,
      "every admission decision must reach the host's configured cache store"
    assert_equal [ 60 ], @application_cache.increments.map { |write| write.fetch(:expires_in) }.uniq,
      "the fixed window must be expressed as the store's own expiry"
    assert @application_cache.increments.all? { |write| write.fetch(:name).start_with?("hitch:mcp:rate-limit:v1:") },
      "admission keys stay namespaced and carry no raw principal identifiers"
  end

  test "an explicit rate limit store overrides the application cache store" do
    dedicated = RecordingCacheStore.new
    configure_runtime(to: 1, within: 60, store: dedicated)

    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :ok
    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :too_many_requests

    assert_equal 2, dedicated.increments.length
    assert_empty @application_cache.increments,
      "an explicit store must not fall through to the application cache"
  end

  test "a cache store failure is 503 before body registry SDK or host work" do
    configure_runtime(to: 3, within: 60, store: BrokenCacheStore.new)
    McpController.reset_wire_metrics!
    input = NonRewindableInput.new(request_body(method: "tools/call", name: "hitch.echo"))

    failed = call_app_with_input(
      path: "/mcp",
      input:,
      content_type: "application/json",
      host: "dummy.test",
      headers: admission_env(token: @token, method: "tools/call", name: "hitch.echo")
    )

    assert_equal 503, failed.status
    assert_nil failed.headers["retry-after"]
    assert_equal 0, input.bytes_read
    assert_equal({ body_parses: 0, registry: 0, sdk: 0, host: 0 }, downstream_metrics)
  end

  test "a nil count admits authenticated traffic, the posture Rails takes" do
    configure_runtime(to: 1, within: 60, store: OutageNilStore.new)

    3.times do
      post_admitted_mcp(method: "tools/list", token: @token)
      assert_response :ok,
        "a store that cannot count must not reject already-authenticated requests"
    end
  end

  test "a store that never overrode increment is 503, not a host 500" do
    # The base ActiveSupport::Cache::Store#increment raises NotImplementedError,
    # which is a ScriptError; admission must still degrade to its designed 503.
    configure_runtime(to: 3, within: 60, store: ActiveSupport::Cache::Store.new)

    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :service_unavailable
  end

  test "a non-numeric count is 503" do
    configure_runtime(to: 3, within: 60, store: GarbageCountStore.new)

    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :service_unavailable
  end

  test "the packaged gem declares no runtime Redis dependency" do
    specification = Gem::Specification.load(REPOSITORY_ROOT.join("hitch-rails.gemspec").to_s)
    runtime = specification.dependencies.select { |dependency| dependency.type == :runtime }

    assert_empty runtime.map(&:name).grep(/redis/),
      "Redis is a host deployment choice, not a Hitch runtime dependency"
  end

  test "no runtime source file requires the redis client" do
    sources = Dir.chdir(REPOSITORY_ROOT) { Dir["app/**/*.rb", "lib/**/*.rb"] }
    offenders = sources.select do |path|
      REPOSITORY_ROOT.join(path).read.match?(/^\s*require\s+["']redis["']/)
    end

    assert_empty offenders,
      "packaged runtime code must not load the redis client"
  end

  private

  def configure_runtime(to:, within:, store: nil)
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = [ "https://allowed.example" ]
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = { name: "hitch-rate", version: "0.2.0" }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to:, within: }
      configuration.mcp.rate_limit_store = store
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
  end

  def mint_token(principal, client_id:)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    authorization = Hitch::AccessToken.create_authorization!(
      principal:,
      client_id:,
      client_name: "Rate Client",
      code_challenge: challenge,
      code_challenge_method: "S256",
      scopes: "mcp",
      resource_uri: RESOURCE
    )
    exchange_authorization_code(authorization, verifier:)
  end

  def downstream_metrics
    McpController.wire_metrics.slice(:body_parses, :registry, :sdk, :host)
      .reverse_merge(body_parses: 0, registry: 0, sdk: 0, host: 0)
  end
end
