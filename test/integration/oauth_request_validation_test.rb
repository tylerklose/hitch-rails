# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"

class OauthRequestValidationTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://example.test/mcp"
  OTHER_RESOURCE = "https://other.test/mcp"
  REDIRECT_URI = "https://client.test/callback"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = RESOURCE
      config.allowed_hosts = [ "www.example.com" ]
    end
    @user = User.create!(email: "oauth-validation@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
    @client = Hitch::Client.register!(
      client_id: "public-a",
      client_name: "Public A",
      redirect_uris: [ REDIRECT_URI ]
    )
    @other_client = Hitch::Client.register!(
      client_id: "public-b",
      client_name: "Public B",
      redirect_uris: [ REDIRECT_URI ]
    )
    post "/sign_in", params: { user_id: @user.id }
    assert_response :success
  end

  test "authorization rejects missing and unsupported response_type distinctly" do
    post "/oauth/authorize", params: authorization_params.except(:response_type)
    assert_oauth_error "invalid_request", /response_type/

    post "/oauth/authorize", params: authorization_params(response_type: "token")
    assert_oauth_error "unsupported_response_type", /response_type/
  end

  test "authorization rejects duplicate scalar names across raw query and form data" do
    post "/oauth/authorize?client_id=first", params: authorization_params(client_id: "second")

    assert_oauth_error "invalid_request", /client_id must not be repeated/
  end

  test "authorization rejects array hash and blank optional security values" do
    post "/oauth/authorize", params: authorization_params(client_id: [ @client.client_id ])
    assert_oauth_error "invalid_request", /client_id must be a scalar string/

    post "/oauth/authorize", params: authorization_params(client_id: { value: @client.client_id })
    assert_oauth_error "invalid_request", /client_id must be a scalar string/

    post "/oauth/authorize", params: authorization_params(state: "")
    assert_oauth_error "invalid_request", /state must not be blank/
  end

  test "token endpoint requires form encoding and rejects security fields in the query" do
    post "/oauth/token", params: token_params(code: "unused"), as: :json
    assert_oauth_error "invalid_request", /x-www-form-urlencoded/

    post "/oauth/token?code=query-code", params: token_params(code: "form-code")
    assert_oauth_error "invalid_request", /code must be sent in the form body/
  end

  test "token endpoint rejects duplicate and structured raw form parameters" do
    raw = URI.encode_www_form(token_params(code: "one").to_a + [ [ "code", "two" ] ])
    post_form(raw)
    assert_oauth_error "invalid_request", /code must not be repeated/

    raw = URI.encode_www_form(token_params(code: "one").except(:client_id)) + "&client_id%5B%5D=public-a"
    post_form(raw)
    assert_oauth_error "invalid_request", /client_id must be a scalar string/
  end

  test "missing public client_id fails before authorization code lookup" do
    post "/oauth/token", params: token_params(code: "unused").except(:client_id)

    assert_oauth_error "invalid_request", /client_id is required/
  end

  test "cross-client failure does not consume the code and a corrected retry succeeds" do
    code = mint_code

    post "/oauth/token", params: token_params(code: code, client_id: @other_client.client_id)
    assert_oauth_error "invalid_grant", /issued to this client/
    assert_pending code

    post "/oauth/token", params: token_params(code: code)
    assert_response :success
  end

  test "resource failure does not consume the code and a corrected retry succeeds" do
    code = mint_code

    post "/oauth/token", params: token_params(code: code, resource: OTHER_RESOURCE)
    assert_oauth_error "invalid_target", /resource/
    assert_pending code

    post "/oauth/token", params: token_params(code: code)
    assert_response :success
  end

  test "PKCE failure does not consume the code and a corrected retry succeeds" do
    code = mint_code

    post "/oauth/token", params: token_params(code: code, code_verifier: "w" * 43)
    assert_oauth_error "invalid_grant", /PKCE/
    assert_pending code

    post "/oauth/token", params: token_params(code: code)
    assert_response :success
  end

  test "canonical-equivalent resource and omitted legacy redirect_uri succeed" do
    code = mint_code

    post "/oauth/token", params: token_params(
      code: code,
      resource: "HTTPS://EXAMPLE.TEST:443/mcp"
    )

    assert_response :success
    assert_nil token_params(code: code)[:redirect_uri]
  end

  private

  def authorization_params(overrides = {})
    {
      response_type: "code",
      client_id: @client.client_id,
      redirect_uri: REDIRECT_URI,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE
    }.merge(overrides)
  end

  def token_params(overrides = {})
    {
      grant_type: "authorization_code",
      code: "unused",
      client_id: @client.client_id,
      code_verifier: @verifier,
      resource: RESOURCE
    }.merge(overrides)
  end

  def mint_code
    Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: @client.client_id,
      client_name: @client.client_name,
      redirect_uri: REDIRECT_URI,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    ).raw_authorization_code
  end

  def post_form(raw_body)
    post "/oauth/token", params: raw_body, headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
  end

  def assert_oauth_error(code, description)
    assert_response :bad_request if response.status != 401
    body = JSON.parse(response.body)
    assert_equal code, body.fetch("error")
    assert_match description, body.fetch("error_description")
  end

  def assert_pending(code)
    assert authorization_code_pending?(code), "failed binding attempt consumed the authorization code"
  end
end
