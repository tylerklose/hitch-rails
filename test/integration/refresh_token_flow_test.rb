# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"
require "hitch/mcp/test_helper"

# The refresh grant through the endpoints a client actually calls. The model
# tests pin the semantics; these pin that the wire reaches them — a refresh
# token that opened /mcp would be a correct model and a broken server.
class RefreshTokenFlowTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  CLIENT_ID = "refresh-flow-client"
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    @user = User.create!(email: "refresh-flow+#{SecureRandom.hex(4)}@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  test "a client exchanges a code, refreshes, and the new access token opens /mcp" do
    issued = exchange_code

    assert_not_nil issued["refresh_token"]

    refreshed = post_refresh(issued.fetch("refresh_token"))

    assert_response :success
    assert_not_equal issued.fetch("access_token"), refreshed.fetch("access_token")
    assert_not_equal issued.fetch("refresh_token"), refreshed.fetch("refresh_token")
    assert_equal "Bearer", refreshed.fetch("token_type")

    post_mcp(method: "tools/list", token: refreshed.fetch("access_token"))
    assert_response :success
  end

  # Trap 4, at the layer that decides it. find_by_token reads token_digest
  # only; this fails the moment that stops being true.
  test "a refresh token cannot open /mcp" do
    issued = exchange_code

    post_mcp(method: "tools/list", token: issued.fetch("refresh_token"))

    assert_response :unauthorized
  end

  test "a replayed refresh token past the grace window kills the family's access tokens" do
    issued = exchange_code
    refreshed = post_refresh(issued.fetch("refresh_token"))
    post_mcp(method: "tools/list", token: refreshed.fetch("access_token"))
    assert_response :success

    Hitch::AccessToken.find_by_refresh_token(issued.fetch("refresh_token"))
      .update_columns(refresh_consumed_at: 1.hour.ago)
    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: issued.fetch("refresh_token"),
      client_id: CLIENT_ID,
      resource: RESOURCE
    }
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body).fetch("error")

    post_mcp(method: "tools/list", token: refreshed.fetch("access_token"))
    assert_response :unauthorized
  end

  test "revoking a refresh token revokes the whole family" do
    issued = exchange_code
    refreshed = post_refresh(issued.fetch("refresh_token"))

    post "/oauth/revoke", params: { token: refreshed.fetch("refresh_token") }
    assert_response :success

    post_mcp(method: "tools/list", token: refreshed.fetch("access_token"))
    assert_response :unauthorized
  end

  test "discovery advertises refresh_token only while the grant is enabled" do
    get "/.well-known/oauth-authorization-server"
    assert_includes JSON.parse(response.body).fetch("grant_types_supported"), "refresh_token"

    Hitch.configuration.refresh_tokens_enabled = false

    get "/.well-known/oauth-authorization-server"
    refute_includes JSON.parse(response.body).fetch("grant_types_supported"), "refresh_token"
  end

  test "the disabled grant is refused at the endpoint" do
    issued = exchange_code
    Hitch.configuration.refresh_tokens_enabled = false

    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: issued.fetch("refresh_token"),
      client_id: CLIENT_ID,
      resource: RESOURCE
    }

    assert_response :bad_request
    assert_equal "unsupported_grant_type", JSON.parse(response.body).fetch("error")
  end

  private

  def exchange_code
    record = Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: CLIENT_ID,
      client_name: CLIENT_ID,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    )
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: record.raw_authorization_code,
      client_id: CLIENT_ID,
      code_verifier: @verifier,
      resource: RESOURCE
    }
    assert_response :success
    JSON.parse(response.body)
  end

  def post_refresh(raw_refresh_token)
    post "/oauth/token", params: {
      grant_type: "refresh_token",
      refresh_token: raw_refresh_token,
      client_id: CLIENT_ID,
      resource: RESOURCE
    }
    JSON.parse(response.body)
  end
end
