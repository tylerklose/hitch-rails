# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"
require_relative "../support/mcp_wire_admission_support"

class MCPRateLimitTest < ActionDispatch::IntegrationTest
  include McpWireAdmissionSupport
  RESOURCE = "https://dummy.test/mcp"

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    McpController.wire_slice_enabled = true
    configure_runtime(to: 3, within: 60)
    @user = User.create!(email: "rate@example.test")
    @token = mint_token(@user, client_id: "shared-client")
    McpController.reset_wire_metrics!
  end

  teardown do
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
  end

  test "discover list and call share one exact authenticated boundary" do
    post_admitted_mcp(method: "server/discover", token: @token)
    assert_response :ok
    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :ok
    post_admitted_mcp(method: "tools/call", token: @token, name: "hitch.echo",
      arguments: { "message" => "within-limit" })
    assert_response :ok

    before_rejection = downstream_metrics
    input = NonRewindableInput.new(request_body(method: "tools/list", id: "rejected"))
    rejected = call_app_with_input(
      path: "/mcp",
      input:,
      content_type: "application/json",
      host: "dummy.test",
      headers: admission_env(token: @token, method: "tools/list")
    )

    headers = rejected.headers.transform_keys(&:downcase)
    assert_equal 429, rejected.status
    assert_equal "60", headers.fetch("retry-after")
    assert_includes headers.fetch("access-control-expose-headers"), "Retry-After"
    assert_equal 0, input.bytes_read
    assert_equal before_rejection, downstream_metrics
    assert_equal({ body_parses: 3, registry: 3, sdk: 3, host: 1 }, downstream_metrics)
  end

  test "rotating a token does not reset the principal-client quota" do
    configure_runtime(to: 2, within: 60)
    rotated = mint_token(@user, client_id: "shared-client")

    post_admitted_mcp(method: "tools/list", token: @token)
    assert_response :ok
    post_admitted_mcp(method: "server/discover", token: rotated)
    assert_response :ok
    post_admitted_mcp(method: "tools/list", token: rotated)

    assert_response :too_many_requests
    assert_equal "60", response.headers.fetch("Retry-After")
  end

  test "principal and client identities have separate quotas" do
    configure_runtime(to: 1, within: 60)
    other_user = User.create!(email: "other-rate@example.test")
    same_principal_other_client = mint_token(@user, client_id: "other-client")
    other_principal_same_client = mint_token(other_user, client_id: "shared-client")

    [ @token, same_principal_other_client, other_principal_same_client ].each do |token|
      post_admitted_mcp(method: "tools/list", token:)
      assert_response :ok
    end

    [ @token, same_principal_other_client, other_principal_same_client ].each do |token|
      post_admitted_mcp(method: "tools/list", token:)
      assert_response :too_many_requests
    end
  end

  # Store failure is 503 before any downstream work: see
  # MCPRateLimitCacheStoreTest, which owns the store contract.

  private

  def configure_runtime(to:, within:)
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = []
      configuration.allowed_origins = [ "https://allowed.example" ]
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = { name: "hitch-rate", version: "0.2.0" }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
      configuration.mcp.request_limit = { to:, within: }
      configuration.mcp.rate_limit_store = ActiveSupport::Cache::MemoryStore.new
      configuration.mcp.max_request_bytes = 8_192
    end
    Hitch.configuration.validate!
    Hitch.configuration.mcp.prepare_registry!(supported_scopes: Hitch.configuration.supported_scopes)
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
