# frozen_string_literal: true

require "test_helper"
require "base64"
require "json"
require "securerandom"
require "hitch/mcp/test_helper"

# RFC 8628 end to end, exactly as the two parties live it: a headless agent
# minting and polling on one side, its human signing in and approving on the
# other — finishing only when the polled token actually opens /mcp.
class DeviceAuthorizationFlowTest < ActionDispatch::IntegrationTest
  include Hitch::MCP::TestHelper

  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::DeviceGrant.delete_all
    Hitch::Client.delete_all
    Hitch.configure do |config|
      config.device_authorization_enabled = true
      config.device_authorization_rate_store = ActiveSupport::Cache::MemoryStore.new
    end
    @user = User.create!(email: "device-flow+#{SecureRandom.hex(4)}@test")
  end

  # The operator badged this agent once at a console; its secret is the
  # client credential every machine leg presents.
  def operator_credentials
    Hitch::Client.register_confidential!(
      client_id: "nightly-reporter",
      client_name: "Nightly Reporter",
      redirect_uris: [ "https://agent.example/callback" ]
    )
  end

  def basic_auth(credentials)
    encoded = Base64.strict_encode64("#{credentials.client.client_id}:#{credentials.client_secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  def poll(credentials, device_code)
    post "/oauth/token",
      params: {
        grant_type: Hitch::GrantTypes::DEVICE_CODE,
        device_code: device_code,
        resource: RESOURCE
      },
      headers: basic_auth(credentials)
    JSON.parse(response.body)
  end

  test "an agent gets a code, its human approves it, and the polled token opens /mcp" do
    credentials = operator_credentials
    post "/oauth/device_authorization",
      params: { resource: RESOURCE }, headers: basic_auth(credentials)
    assert_response :success
    codes = JSON.parse(response.body)

    # The agent polls before its human has acted.
    assert_equal "authorization_pending", poll(credentials, codes.fetch("device_code")).fetch("error")

    # The human follows verification_uri_complete on their phone: sign in,
    # see the prefilled code, submit it, read who is asking, approve.
    post "/sign_in", params: { user_id: @user.id }
    uri = URI.parse(codes.fetch("verification_uri_complete"))
    assert_equal "/activate", uri.path
    get "/activate", params: { user_code: codes.fetch("user_code") }
    assert_response :success
    post "/activate", params: { user_code: codes.fetch("user_code") }
    assert_response :success
    assert_match(/is asking for access/, response.body)
    assert_match(/Nightly Reporter/, response.body)
    post "/activate", params: { user_code: codes.fetch("user_code"), decision: "approve" }
    assert_response :success

    # The agent's next poll, a full interval later, collects the token.
    travel_to(Time.current + 6.seconds) do
      issued = poll(credentials, codes.fetch("device_code"))
      assert_response :success
      assert_equal "Bearer", issued.fetch("token_type")
      assert issued.fetch("refresh_token").present?

      post_mcp(method: "tools/list", token: issued.fetch("access_token"))
      assert_response :success
    end
  end

  test "the human's deny reaches the polling agent as access_denied" do
    credentials = operator_credentials
    post "/oauth/device_authorization",
      params: { resource: RESOURCE }, headers: basic_auth(credentials)
    codes = JSON.parse(response.body)

    post "/sign_in", params: { user_id: @user.id }
    post "/activate", params: { user_code: codes.fetch("user_code"), decision: "deny" }
    assert_response :success

    body = poll(credentials, codes.fetch("device_code"))
    assert_response :bad_request
    assert_equal "access_denied", body.fetch("error")
  end
end
