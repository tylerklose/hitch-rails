# frozen_string_literal: true

require "test_helper"
require "base64"
require "json"
require "securerandom"

# POST /oauth/device_authorization through the wire: the flag's 404 posture,
# client validation without any outbound fetch, the per-IP quota, and a §3.2
# response whose verification_uri never comes from the request.
class DeviceAuthorizationEndpointTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"

  setup do
    Hitch::DeviceGrant.delete_all
    Hitch::Client.delete_all
    Hitch.configure do |config|
      config.device_authorization_enabled = true
      config.device_authorization_rate_store = ActiveSupport::Cache::MemoryStore.new
    end
  end

  def register_client
    post "/oauth/register",
      params: {
        client_name: "Headless Agent",
        redirect_uris: [ "https://agent.example/callback" ]
      }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :created
    JSON.parse(response.body).fetch("client_id")
  end

  def operator_credentials
    Hitch::Client.register_confidential!(
      client_id: "operator-#{SecureRandom.hex(4)}",
      client_name: "Nightly Reporter",
      redirect_uris: [ "https://agent.example/callback" ]
    )
  end

  def basic_auth(credentials)
    encoded = Base64.strict_encode64("#{credentials.client.client_id}:#{credentials.client_secret}")
    { "Authorization" => "Basic #{encoded}" }
  end

  def request_device_authorization(client_id: nil, credentials: nil, scope: nil)
    params = { resource: RESOURCE }
    params[:client_id] = client_id if client_id
    params[:scope] = scope if scope
    post "/oauth/device_authorization", params: params,
      headers: credentials ? basic_auth(credentials) : {}
  end

  test "the device endpoint answers 404 while the feature is off" do
    Hitch.configuration.device_authorization_enabled = false

    request_device_authorization(credentials: operator_credentials)

    assert_response :not_found
    assert_empty response.body
  end

  test "an oversized body to the disabled endpoint answers 404, not a body-cap error" do
    Hitch.configuration.device_authorization_enabled = false

    post "/oauth/device_authorization", params: { client_id: "A" * 20_000, resource: RESOURCE }

    assert_response :not_found
    assert_empty response.body
  end

  test "an operator client authenticates with its secret and mints the RFC 8628 response" do
    request_device_authorization(credentials: operator_credentials)

    assert_response :success
    assert_equal "no-store", response.headers["Cache-Control"]
    body = JSON.parse(response.body)
    assert_match(/\A[0-9A-Z]{4}-[0-9A-Z]{4}\z/, body.fetch("user_code"))
    assert body.fetch("device_code").present?
    assert_equal "https://dummy.test/activate", body.fetch("verification_uri")
    assert_equal "https://dummy.test/activate?user_code=#{body.fetch('user_code')}",
      body.fetch("verification_uri_complete")
    assert_equal Hitch.configuration.device_code_lifetime_seconds, body.fetch("expires_in")
    assert_equal 5, body.fetch("interval")
  end

  test "an unknown registered client cannot mint a device code" do
    request_device_authorization(client_id: "never-registered")

    assert_response :unauthorized
    assert_equal "invalid_client", JSON.parse(response.body).fetch("error")
    assert_equal 0, Hitch::DeviceGrant.count
  end

  test "a wrong secret is challenged under the device endpoint's own realm" do
    credentials = operator_credentials
    wrong = Base64.strict_encode64("#{credentials.client.client_id}:not-the-secret")

    post "/oauth/device_authorization", params: { resource: RESOURCE },
      headers: { "Authorization" => "Basic #{wrong}" }

    assert_response :unauthorized
    assert_equal 'Basic realm="oauth/device_authorization"', response.headers["WWW-Authenticate"]
    assert_equal "invalid_client", JSON.parse(response.body).fetch("error")
  end

  test "a self-registered public client cannot mint a device code" do
    # Anyone can register one, so it vouches for nobody — the §5.4 shape.
    request_device_authorization(client_id: register_client)

    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "invalid_client", body.fetch("error")
    assert_includes body.fetch("error_description"), "operator-registered"
    assert_equal 0, Hitch::DeviceGrant.count
  end

  test "a registered public client cannot mint even behind a metadata-shaped id" do
    # The registered row decides first, exactly as /activate classifies —
    # otherwise this grant would mint and then sit unapprovable.
    Hitch.configuration.client_id_metadata_enabled = true
    Hitch::Client.register!(
      client_id: "https://agent.example/oauth-client",
      client_name: "Squatter",
      redirect_uris: [ "https://agent.example/cb" ]
    )

    request_device_authorization(client_id: "https://agent.example/oauth-client")

    assert_response :unauthorized
    assert_equal "invalid_client", JSON.parse(response.body).fetch("error")
    assert_equal 0, Hitch::DeviceGrant.count
  end

  test "a metadata client_id mints without any outbound fetch" do
    Hitch.configuration.client_id_metadata_enabled = true
    fetch_forbidden = ->(*, **) { raise "the mint endpoint must never fetch client metadata" }

    stub_class_method(Hitch::ClientIdMetadata, :resolve, fetch_forbidden) do
      request_device_authorization(client_id: "https://agent.example/oauth-client")
    end

    assert_response :success
    assert_equal "https://agent.example/oauth-client", Hitch::DeviceGrant.sole.client_id
  end

  test "the requested scope is clamped to what the host supports at mint" do
    request_device_authorization(credentials: operator_credentials, scope: "mcp payments:write")

    assert_response :success
    assert_equal "mcp", Hitch::DeviceGrant.sole.scopes
  end

  test "mint requests beyond the per-IP limit are refused with Retry-After" do
    Hitch.configuration.device_authorization_limit = { to: 2, within: 60 }
    credentials = operator_credentials

    2.times do
      request_device_authorization(credentials: credentials)
      assert_response :success
    end
    request_device_authorization(credentials: credentials)

    assert_response :too_many_requests
    assert_equal "60", response.headers["Retry-After"]
    assert_equal "temporarily_unavailable", JSON.parse(response.body).fetch("error")
    assert_equal 2, Hitch::DeviceGrant.count
  end

  test "a JSON body is refused; the endpoint speaks form encoding only" do
    post "/oauth/device_authorization",
      params: { client_id: "x", resource: RESOURCE }.to_json,
      headers: { "Content-Type" => "application/json" }

    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body).fetch("error")
  end

  test "discovery advertises the device endpoint only while enabled" do
    get "/.well-known/oauth-authorization-server"
    body = JSON.parse(response.body)
    assert_equal "https://dummy.test/oauth/device_authorization", body.fetch("device_authorization_endpoint")
    assert_includes body.fetch("grant_types_supported"), Hitch::GrantTypes::DEVICE_CODE

    Hitch.configuration.device_authorization_enabled = false

    get "/.well-known/oauth-authorization-server"
    body = JSON.parse(response.body)
    refute body.key?("device_authorization_endpoint")
    refute_includes body.fetch("grant_types_supported"), Hitch::GrantTypes::DEVICE_CODE
  end
end
