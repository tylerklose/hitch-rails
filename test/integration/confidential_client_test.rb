# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"
require "stringio"

class ConfidentialClientTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://example.test/mcp"
  REDIRECT_URI = "https://client.test/callback"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = RESOURCE
      config.allowed_hosts = [ "www.example.com" ]
      config.dynamic_client_registration_enabled = true if
        config.respond_to?(:dynamic_client_registration_enabled=)
    end
    @user = User.create!(email: "confidential-client@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  test "public and confidential clients can exchange authorization codes" do
    public_client = Hitch::Client.register!(
      client_id: "public-client",
      client_name: "Public",
      redirect_uris: [ REDIRECT_URI ]
    )
    public_code = mint_code(public_client)

    post "/oauth/token", params: token_params(public_code, client_id: public_client.client_id)
    assert_response :success

    credentials = register_confidential("confidential-client")
    confidential_code = mint_code(credentials.client)

    post "/oauth/token",
      params: token_params(confidential_code),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :success
  end

  test "wrong and malformed Basic credentials return generic 401 without consuming the code" do
    credentials = register_confidential("protected-client")
    code = mint_code(credentials.client)

    [
      { "Authorization" => "Basic not-base64!" },
      basic_header(credentials.client.client_id, "wrong-secret"),
      { "Authorization" => "Basic #{Base64.strict_encode64("missing-colon")}" },
      { "Authorization" => "Basic #{Base64.strict_encode64("\xFF:secret")}" }
    ].each do |headers|
      post "/oauth/token", params: token_params(code), headers: headers
      assert_invalid_client
      assert authorization_code_pending?(code)
    end

    post "/oauth/token",
      params: token_params(code),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :success
  end

  test "Basic scheme is case-insensitive and form-decodes client credentials" do
    credentials = register_confidential("client id:+")
    code = mint_code(credentials.client)
    header = basic_header(credentials.client.client_id, credentials.client_secret)
    header["Authorization"].sub!("Basic", "bAsIc")

    post "/oauth/token", params: token_params(code), headers: header

    assert_response :success
  end

  test "body secrets and multiple client authentication methods are rejected before consumption" do
    credentials = register_confidential("single-method")
    code = mint_code(credentials.client)

    post "/oauth/token", params: token_params(
      code,
      client_id: credentials.client.client_id,
      client_secret: credentials.client_secret
    )
    assert_oauth_error "invalid_request", /client_secret/
    assert authorization_code_pending?(code)

    post "/oauth/token",
      params: token_params(code, client_id: credentials.client.client_id),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_oauth_error "invalid_request", /exactly one authentication method/
    assert authorization_code_pending?(code)
  end

  test "rotating a confidential secret rejects the old value and accepts the new one" do
    original = register_confidential("rotating-client")
    rotated = original.client.rotate_secret!
    code = mint_code(original.client)

    post "/oauth/token",
      params: token_params(code),
      headers: basic_header(original.client.client_id, original.client_secret)
    assert_invalid_client
    assert authorization_code_pending?(code)

    post "/oauth/token",
      params: token_params(code),
      headers: basic_header(original.client.client_id, rotated.client_secret)
    assert_response :success
  end

  test "DCR emits confidential secret fields once and stores no plaintext" do
    post "/oauth/register", params: {
      client_name: "Deployment Bot",
      redirect_uris: [ REDIRECT_URI ],
      token_endpoint_auth_method: "client_secret_basic"
    }, as: :json

    assert_response :created
    body = JSON.parse(response.body)
    secret = body.fetch("client_secret")
    client = Hitch::Client.find_by!(client_id: body.fetch("client_id"))
    assert_equal "client_secret_basic", body.fetch("token_endpoint_auth_method")
    assert_equal client.client_secret_issued_at.to_i, body.fetch("client_secret_issued_at")
    assert_equal 0, body.fetch("client_secret_expires_at")
    assert client.authenticates_secret?(secret)
    refute_includes client.attributes.values, secret
    refute_includes client.attributes.to_json, secret
  end

  test "public DCR response has no secret fields and unsupported auth methods fail" do
    post "/oauth/register", params: {
      client_name: "Public",
      redirect_uris: [ REDIRECT_URI ],
      token_endpoint_auth_method: "none"
    }, as: :json
    assert_response :created
    body = JSON.parse(response.body)
    assert_equal "none", body.fetch("token_endpoint_auth_method")
    assert_nil body["client_secret"]
    assert_nil body["client_secret_issued_at"]
    assert_nil body["client_secret_expires_at"]

    post "/oauth/register", params: {
      client_name: "Unsupported",
      redirect_uris: [ REDIRECT_URI ],
      token_endpoint_auth_method: "client_secret_post"
    }, as: :json
    assert_oauth_error "invalid_client_metadata", /token_endpoint_auth_method/
  end

  test "metadata advertises exactly the two implemented authentication methods" do
    get "/.well-known/oauth-authorization-server"

    methods = JSON.parse(response.body).fetch("token_endpoint_auth_methods_supported")
    assert_equal %w[none client_secret_basic], methods
  end

  test "control and oversized Basic credentials fail before lookup without consuming the code" do
    credentials = register_confidential("bounded-basic")
    code = mint_code(credentials.client)
    headers = [
      { "Authorization" => "Basic #{Base64.strict_encode64('%00:secret')}" },
      { "Authorization" => "Basic #{Base64.strict_encode64("#{'a' * 200_000}:secret")}" }
    ]
    lookup = ->(**) { flunk "malformed Basic credentials must not reach client lookup" }

    headers.each do |header|
      stub_class_method(Hitch::Client, :find_by, lookup) do
        post "/oauth/token", params: token_params(code), headers: header
      end
      assert_invalid_client
      assert authorization_code_pending?(code)
    end

    post "/oauth/token",
      params: token_params(code),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :success
  end

  test "one-time credentials redact inspection and reject serialization" do
    credentials = register_confidential("redacted-client")
    secret = credentials.client_secret

    assert credentials.frozen?
    assert credentials.client_secret.frozen?
    assert_includes credentials.inspect, "[FILTERED]"
    refute_includes credentials.inspect, secret
    refute_includes credentials.to_s, secret
    assert_raises(Hitch::Client::Credentials::SerializationForbidden) { credentials.to_h }
    assert_raises(Hitch::Client::Credentials::SerializationForbidden) { credentials.as_json }
    assert_raises(Hitch::Client::Credentials::SerializationForbidden) { credentials.to_json }
    assert_raises(Hitch::Client::Credentials::SerializationForbidden) { JSON.generate(credentials) }

    output = StringIO.new
    ActiveSupport::Logger.new(output).info(credentials)
    assert_includes output.string, "[FILTERED]"
    refute_includes output.string, secret
  end

  test "parameter filters include every client secret field" do
    filter = ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters)
    filtered = filter.filter(
      "client_secret" => "secret-canary",
      "client_secret_digest" => "digest-canary"
    )

    assert_equal "[FILTERED]", filtered.fetch("client_secret")
    assert_equal "[FILTERED]", filtered.fetch("client_secret_digest")
  end

  private

  def register_confidential(client_id)
    Hitch::Client.register_confidential!(
      client_id: client_id,
      client_name: "Confidential",
      redirect_uris: [ REDIRECT_URI ]
    )
  end

  def mint_code(client)
    Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uri: REDIRECT_URI,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    ).raw_authorization_code
  end

  def token_params(code, **overrides)
    {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier,
      resource: RESOURCE
    }.merge(overrides)
  end

  def basic_header(client_id, client_secret)
    username = URI.encode_www_form_component(client_id)
    password = URI.encode_www_form_component(client_secret)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end

  def assert_invalid_client
    assert_response :unauthorized
    body = JSON.parse(response.body)
    assert_equal "invalid_client", body.fetch("error")
    assert_equal "Client authentication failed", body.fetch("error_description")
    assert_equal 'Basic realm="oauth/token"', response.headers["WWW-Authenticate"]
  end

  def assert_oauth_error(code, description)
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal code, body.fetch("error")
    assert_match description, body.fetch("error_description")
  end
end
