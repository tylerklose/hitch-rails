# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"

# M4.3 erratum acceptance.
#
# Hitch admits authenticated MCP requests through the host application's own
# ActiveSupport::Cache store, exactly as Rails' ActionController::RateLimiting
# does. Redis remains one supported backend; it is never a required service and
# never a runtime gem dependency. A Solid Cache application must install Hitch
# and reach production without introducing Redis.
class MCPRateLimitCacheStoreTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"
  REPOSITORY_ROOT = Rails.root.join("../..").expand_path

  # Records every admission write so the tests can prove which store the
  # endpoint reached, not merely that some counter advanced.
  class RecordingCacheStore < ActiveSupport::Cache::MemoryStore
    attr_reader :increments

    def initialize(*arguments)
      super
      @increments = []
    end

    def increment(name, amount = 1, options = nil)
      @increments << { name: name, amount: amount, expires_in: options && options[:expires_in] }
      super
    end
  end

  # A store that cannot count. Admission must fail closed rather than admit.
  class BrokenCacheStore < ActiveSupport::Cache::MemoryStore
    def increment(*)
      raise Errno::ECONNREFUSED, "cache backend unavailable"
    end
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
      post_mcp(method: "tools/list", token: @token)
      assert_response :ok
    end

    post_mcp(method: "tools/list", token: @token)
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

    post_mcp(method: "tools/list", token: @token)
    assert_response :ok
    post_mcp(method: "tools/list", token: @token)
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
      headers: request_headers(token: @token, method: "tools/call", name: "hitch.echo")
    )

    assert_equal 503, failed.status
    assert_nil failed.headers["retry-after"]
    assert_equal 0, input.bytes_read
    assert_equal({ body_parses: 0, registry: 0, sdk: 0, host: 0 }, downstream_metrics)
  end

  test "rotating a token does not reset the principal client quota" do
    configure_runtime(to: 2, within: 60)
    rotated = mint_token(@user, client_id: "shared-client")

    post_mcp(method: "tools/list", token: @token)
    assert_response :ok
    post_mcp(method: "server/discover", token: rotated)
    assert_response :ok
    post_mcp(method: "tools/list", token: rotated)

    assert_response :too_many_requests
  end

  test "principal and client identities keep separate quotas" do
    configure_runtime(to: 1, within: 60)
    other_user = User.create!(email: "other-cache-rate@example.test")
    same_principal_other_client = mint_token(@user, client_id: "other-client")
    other_principal_same_client = mint_token(other_user, client_id: "shared-client")

    [ @token, same_principal_other_client, other_principal_same_client ].each do |token|
      post_mcp(method: "tools/list", token:)
      assert_response :ok
    end

    [ @token, same_principal_other_client, other_principal_same_client ].each do |token|
      post_mcp(method: "tools/list", token:)
      assert_response :too_many_requests
    end
  end

  test "production boot succeeds with no Redis configuration" do
    configuration = Hitch::MCP::Configuration.new
    configuration.registry = "McpToolRegistry"
    configuration.server_info = ->(_context) { { name: "solid-cache-app", version: "1.0.0" } }
    configuration.scope_resolver = ->(principal:, access_token:, request:) { principal }
    configuration.request_limit = { to: 120, within: 60 }

    original = Rails.env
    begin
      Rails.env = "production"
      assert configuration.validate!,
        "a Solid Cache application must reach production without configuring Redis"
    ensure
      Rails.env = original.to_s
    end
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
      configuration.mcp.server_info = ->(_context) { { name: "hitch-rate", version: "0.2.0" } }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to:, within: }
      configuration.mcp.rate_limit_store = store
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
    Hitch.configuration.mcp.__send__(
      :prepare_registry!,
      supported_scopes: Hitch.configuration.supported_scopes
    )
  end

  def post_mcp(method:, token:, name: nil, arguments: {}, id: SecureRandom.hex(4))
    headers = {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => PROTOCOL_VERSION,
      "Mcp-Method" => method,
      "X-Hitch-Wire-Admission" => "runtime"
    }
    headers["Mcp-Name"] = name if name
    post "/mcp", params: request_body(method:, name:, arguments:, id:), headers:
  end

  def request_body(method:, name: nil, arguments: {}, id: SecureRandom.hex(4))
    params = {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientCapabilities" => {}
      }
    }
    if method == "tools/call"
      params["name"] = name
      params["arguments"] = arguments
    end
    JSON.generate(jsonrpc: "2.0", id:, method:, params:)
  end

  def request_headers(token:, method:, name: nil)
    {
      "CONTENT_TYPE" => "application/json",
      "HTTP_HOST" => "dummy.test",
      "HTTP_AUTHORIZATION" => "Bearer #{token}",
      "HTTP_ACCEPT" => "application/json, text/event-stream",
      "HTTP_MCP_PROTOCOL_VERSION" => PROTOCOL_VERSION,
      "HTTP_MCP_METHOD" => method,
      "HTTP_X_HITCH_WIRE_ADMISSION" => "runtime"
    }.tap do |headers|
      headers["HTTP_MCP_NAME"] = name if name
    end
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
