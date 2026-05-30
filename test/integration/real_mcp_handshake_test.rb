# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"
require "mcp"

# End-to-end through a REAL ::MCP::Server (the official `mcp` SDK, test-only
# dep) wired via Hitch::ServerEndpoint — the dummy RealMcpController. Where
# mcp_server_endpoint_test.rb simulates the SDK return contract, this drives
# the actual handshake Grok performs and asserts the gem shapes the real SDK
# output correctly. This is the regression guard for the production Grok bug:
#
#   initialize               -> 200 + application/json
#   notifications/initialized -> 202 Accepted, empty body   <-- the fix
#   tools/list               -> 200, lists the real tool    <-- Grok reaches this
#
# Sent with protocolVersion 2025-03-26 (Grok's, and SDK-supported), and with
# NO Mcp-Session-Id (Grok sends none; stateless is spec-valid).
class RealMCPHandshakeTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE
      c.supported_scopes = [ "mcp" ]
    end
    @user = User.create!(email: "mcp@test")
    @auth = {
      "Authorization" => "Bearer #{mint_token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream"
    }
  end

  def mint_token
    verifier = SecureRandom.urlsafe_base64(64)
    challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    record = Hitch::AccessToken.create_authorization!(
      principal: @user, client_id: "c", client_name: "C",
      code_challenge: challenge, code_challenge_method: "S256",
      resource_uri: RESOURCE
    )
    record.consume_code!(verifier)
  end

  def rpc(payload)
    post "/real_mcp", params: payload.to_json, headers: @auth
  end

  test "full Grok handshake: initialize -> notification(202) -> tools/list" do
    # 1. initialize — a request, expects a result
    rpc(
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: {
        protocolVersion: "2025-03-26",
        capabilities: {},
        clientInfo: { name: "grok-connectors-manager", version: "0.1.0" }
      }
    )
    assert_response :ok
    assert_match %r{application/json}, response.media_type
    init = JSON.parse(response.body)
    assert_equal 1, init["id"]
    assert init.dig("result", "protocolVersion").present?, "initialize must return a result"

    # 2. notifications/initialized — the line that bricked Grok.
    #    MUST be 202 Accepted with an empty body (not 200 + empty).
    rpc(jsonrpc: "2.0", method: "notifications/initialized")
    assert_response :accepted
    assert_predicate response.body, :blank?

    # 3. tools/list — the request Grok only reaches if step 2 was 202.
    rpc(jsonrpc: "2.0", id: 2, method: "tools/list")
    assert_response :ok
    tools = JSON.parse(response.body).dig("result", "tools")
    assert_equal [ "echo" ], tools.map { |t| t["name"] },
      "the real MCP server must surface its tool through Hitch::ServerEndpoint"
  end

  test "tools/call through the real server returns 200 + JSON" do
    rpc(
      jsonrpc: "2.0", id: 3, method: "tools/call",
      params: { name: "echo", arguments: { text: "hi" } }
    )
    assert_response :ok
    body = JSON.parse(response.body)
    assert_equal 3, body["id"]
    assert_equal "hi", body.dig("result", "content", 0, "text")
  end

  test "unauthenticated real MCP request is 401 with discovery challenge" do
    post "/real_mcp",
      params: { jsonrpc: "2.0", id: 1, method: "tools/list" }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :unauthorized
    assert_match(/resource_metadata=/, response.headers["WWW-Authenticate"].to_s)
  end
end
