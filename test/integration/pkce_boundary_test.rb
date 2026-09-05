# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"

class PkceBoundaryTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
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
    @user = User.create!(email: "pkce-boundary@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
    @client = Hitch::Client.register!(
      client_id: "pkce-client",
      client_name: "PKCE",
      redirect_uris: [ REDIRECT_URI ]
    )
  end

  test "authorization rejects malformed S256 challenges before persistence" do
    post "/sign_in", params: { user_id: @user.id }
    assert_response :success

    [ "a" * 42, "a" * 44, ("a" * 42) + "%" ].each do |challenge|
      post "/oauth/authorize", params: authorization_params(code_challenge: challenge)
      assert_response :bad_request
    end

    assert_equal 0, Hitch::AccessToken.count
  end

  test "malformed verifiers reject before exchange lookup and leave the code usable" do
    [ "a" * 42, "a" * 129, ("a" * 42) + "%" ].each do |verifier|
      record = mint_code
      raw_code = record.raw_authorization_code
      exchange = ->(**) { flunk "malformed verifier must not reach code lookup/CAS" }

      stub_class_method(Hitch::AccessToken, :exchange_authorization_code!, exchange) do
        post "/oauth/token", params: token_params(raw_code, verifier)
      end

      assert_response :bad_request
      assert_equal "invalid_grant", JSON.parse(response.body).fetch("error")
      assert authorization_code_pending?(raw_code)
    end
  end

  test "a rejected malformed verifier does not prevent a later valid exchange" do
    record = mint_code
    raw_code = record.raw_authorization_code

    post "/oauth/token", params: token_params(raw_code, "short")
    assert_response :bad_request
    assert authorization_code_pending?(raw_code)

    post "/oauth/token", params: token_params(raw_code, @verifier)
    assert_response :success
    refute authorization_code_pending?(raw_code)
  end

  test "oversized token body halts before code lookup" do
    record = mint_code
    raw_code = record.raw_authorization_code
    body = URI.encode_www_form(token_params(raw_code, "a" * 200_000))
    exchange = ->(**) { flunk "oversized body must not reach code lookup/CAS" }

    stub_class_method(Hitch::AccessToken, :exchange_authorization_code!, exchange) do
      post "/oauth/token", params: body,
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end

    assert_response 413
    assert authorization_code_pending?(raw_code)
  end

  test "oversized authorization body halts before code persistence" do
    body = "code_challenge=#{'a' * 200_000}"
    create = ->(**) { flunk "oversized body must not persist an authorization" }

    stub_class_method(Hitch::AccessToken, :create_authorization!, create) do
      post "/oauth/authorize", params: body,
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end

    assert_response 413
    assert_equal 0, Hitch::AccessToken.count
  end

  private

  def mint_code
    Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: @client.client_id,
      client_name: @client.client_name,
      redirect_uri: REDIRECT_URI,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    )
  end

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

  def token_params(code, verifier)
    {
      grant_type: "authorization_code",
      code: code,
      client_id: @client.client_id,
      code_verifier: verifier,
      resource: RESOURCE
    }
  end
end
