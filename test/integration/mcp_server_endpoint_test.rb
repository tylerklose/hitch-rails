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
      c.resource_uri = RESOURCE # tokens are validated against this
      c.allowed_hosts = [ "www.example.com" ]
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
    exchange_authorization_code(record, verifier: verifier)
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

  # WWW-Authenticate is not CORS-safelisted, so a browser-based MCP
  # client cannot read it off a cross-origin 401 unless it is explicitly
  # exposed. It is the only pointer to the Protected Resource Metadata
  # document, so without this the client sees an opaque failure and can
  # never start the OAuth flow.
  test "the 401 challenge is readable cross-origin (Access-Control-Expose-Headers)" do
    post "/mcp_test", params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
                      headers: { "CONTENT_TYPE" => "application/json" }
    assert_response :unauthorized
    assert_includes response.headers["Access-Control-Expose-Headers"].to_s, "WWW-Authenticate"
  end

  test "a request without a bearer token is 401 with a WWW-Authenticate challenge" do
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" }, headers: {})
    assert_response :unauthorized
    challenge = response.headers["WWW-Authenticate"].to_s
    assert_match(/\ABearer /, challenge)
    assert_match(%r{resource_metadata="[^"]+/\.well-known/oauth-protected-resource"}, challenge)
    assert_match(/scope="mcp"/, challenge)
  end

  test "Bearer parsing is strict before lookup and case-insensitive for one valid credential" do
    malformed = [
      "Bearer #{@auth.fetch('Authorization')},other",
      "Bearer token\nsmuggled",
      "Bearer #{'a' * (Hitch::ServerEndpoint::MAX_BEARER_TOKEN_BYTES + 1)}",
      "Bearer  two-spaces",
      "Basic token"
    ]
    lookup = ->(*) { flunk "malformed bearer credential must not reach token lookup" }

    malformed.each do |authorization|
      stub_class_method(Hitch::AccessToken, :find_by_token, lookup) do
        post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" },
          headers: { "Authorization" => authorization })
      end
      assert_response :unauthorized
    end

    mixed_case = @auth.fetch("Authorization").sub("Bearer", "bEaReR")
    post_mcp({ jsonrpc: "2.0", id: 1, method: "tools/list" },
      headers: { "Authorization" => mixed_case })
    assert_response :success
  end

  test "an invalid Host halts before bearer lookup and emits no reflected challenge" do
    lookup = ->(*) { flunk "bearer lookup must not run for an invalid Host" }

    stub_class_method(Hitch::AccessToken, :find_by_token, lookup) do
      post "/mcp_test",
        params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
        headers: {
          "Authorization" => "Bearer attacker-controlled",
          "Content-Type" => "application/json",
          "Host" => "attacker.example"
        }
    end

    assert_response :bad_request
    assert_nil response.headers["WWW-Authenticate"]
    assert_equal "invalid_request", JSON.parse(response.body).fetch("error")
  end

  test "the canonical resource Host may produce the discovery challenge" do
    post "/mcp_test",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json", "Host" => "dummy.test", "HTTPS" => "on" }

    assert_response :unauthorized
    assert_includes response.headers.fetch("WWW-Authenticate"),
      'resource_metadata="https://dummy.test/.well-known/oauth-protected-resource"'
  end

  test "an explicitly allowed proxy Host may produce the discovery challenge" do
    post "/mcp_test",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json", "Host" => "www.example.com", "HTTPS" => "on" }

    assert_response :unauthorized
    assert_includes response.headers.fetch("WWW-Authenticate"),
      'resource_metadata="https://dummy.test/.well-known/oauth-protected-resource"'
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
