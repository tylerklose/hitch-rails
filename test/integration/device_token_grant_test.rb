# frozen_string_literal: true

require "test_helper"
require "json"
require "securerandom"

# grant_type=urn:ietf:params:oauth:grant-type:device_code at POST
# /oauth/token. The model tests pin the state machine; these pin the wire
# plumbing — the §3.5 answers all ride one rescue, so pending/slow_down and
# the happy path prove it, and the flow test covers deny end to end.
class DeviceTokenGrantTest < ActionDispatch::IntegrationTest
  CLIENT_ID = "device-poll-client"
  RESOURCE = "https://dummy.test/mcp"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::DeviceGrant.delete_all
    Hitch.configure { |config| config.device_authorization_enabled = true }
    @user = User.create!(email: "device-poll+#{SecureRandom.hex(4)}@test")
    @grant = Hitch::DeviceGrant.mint!(client_id: CLIENT_ID, scopes: "mcp", resource_uri: RESOURCE)
  end

  def poll(device_code: @grant.raw_device_code, client_id: CLIENT_ID)
    post "/oauth/token", params: {
      grant_type: Hitch::GrantTypes::DEVICE_CODE,
      device_code: device_code,
      client_id: client_id,
      resource: RESOURCE
    }
    JSON.parse(response.body)
  end

  test "a pending grant answers authorization_pending, then slow_down when polled again at once" do
    body = poll
    assert_response :bad_request
    assert_equal "authorization_pending", body.fetch("error")

    body = poll
    assert_response :bad_request
    assert_equal "slow_down", body.fetch("error")
  end

  test "an approved grant releases the token once, then invalid_grant" do
    assert Hitch::DeviceGrant.approve!(user_code: @grant.raw_user_code, principal: @user)

    body = poll
    assert_response :success
    assert_equal "Bearer", body.fetch("token_type")
    assert_equal "mcp", body.fetch("scope")
    assert body.fetch("refresh_token").present?
    assert Hitch::AccessToken.find_by_token(body.fetch("access_token")).accessible?

    assert_equal "invalid_grant", poll.fetch("error")
    assert_response :bad_request
  end

  test "a missing device_code is invalid_request" do
    post "/oauth/token", params: {
      grant_type: Hitch::GrantTypes::DEVICE_CODE, client_id: CLIENT_ID, resource: RESOURCE
    }

    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body).fetch("error")
  end

  test "the disabled grant is refused at the token endpoint" do
    assert Hitch::DeviceGrant.approve!(user_code: @grant.raw_user_code, principal: @user)
    Hitch.configuration.device_authorization_enabled = false

    assert_equal "unsupported_grant_type", poll.fetch("error")
    assert_response :bad_request

    # Even a malformed request: while the feature is off, this grant type
    # has exactly one answer and runs no validation.
    post "/oauth/token", params: { grant_type: Hitch::GrantTypes::DEVICE_CODE, client_id: CLIENT_ID }
    assert_equal "unsupported_grant_type", JSON.parse(response.body).fetch("error")
  end
end
