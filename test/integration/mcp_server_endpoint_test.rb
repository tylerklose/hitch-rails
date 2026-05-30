# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

# Exercises Hitch::ServerEndpoint through test/dummy's McpTestController.
# Pins the MCP Streamable HTTP response contract that strict clients (Grok)
# enforce — the bug that bricked Grok's connector in production:
#   - notification (no id) -> 202 Accepted, empty body
#   - request (has id)     -> 200 + application/json
#   - missing/invalid token -> 401 + WWW-Authenticate discovery challenge
#   - audience-mismatched token -> 401 (RFC 8707)
# Plus the RFC 9728 §3.1 path-aware protected-resource metadata route.
class MCPServerEndpointTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE # tokens are validated against this
      c.supported_scopes = [ "mcp" ]
    end
    @user = User.create!(email: "mcp@test")
    @auth = { "Authorization" => "Bearer #{mint_token(RESOURCE)}" }
  end

  # Mint an ACTIVE token bound to `resource` and return its raw value.
  def mint_token(resource)
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    record = Hitch::AccessToken.create_authorization!(
      principal: @user, client_id: "c", client_name: "C",
      code_challenge: challenge, code_challenge_method: "S256",
      resource_uri: resource
    )
    record.consume_code!(verifier)
  end

  def post_mcp(payload, headers: @auth)
    post "/mcp_test", params: payload.to_json,
      headers: headers.merge("Content-Type" => "application/json")
  end

  test "a JSON-RPC notification returns 202 Accepted with an empty body" do
    post_mcp({ jsonrpc: "2.0", method: "notifications/initialized" })
    assert_response :accepted
    assert_predicate response.body, :blank?
  end

  test "a JSON-RPC request returns 200 with an application/json body" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" })
    assert_response :ok
    assert_match %r{application/json}, response.media_type
    assert_equal 1, JSON.parse(response.body)["id"]
  end

  test "a request without a bearer token is 401 with a WWW-Authenticate challenge" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: {})
    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"].to_s
    assert_match(/\ABearer /, challenge)
    assert_match(%r{resource_metadata="[^"]+/\.well-known/oauth-protected-resource"}, challenge)
    assert_match(/scope="mcp"/, challenge)
  end

  test "a token bound to a different resource is rejected (RFC 8707)" do
    foreign = { "Authorization" => "Bearer #{mint_token('https://elsewhere.test/mcp')}" }
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: foreign)
    assert_response :unauthorized
  end

  test "path-aware protected-resource metadata (RFC 9728 §3.1) is served" do
    get "/.well-known/oauth-protected-resource/mcp"
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal RESOURCE, body["resource"]
    assert_equal [ "mcp" ], body["scopes_supported"]
  end
end
