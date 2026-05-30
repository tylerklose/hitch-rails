# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

class OAuthFlowTest < ActionDispatch::IntegrationTest
  RESOURCE_A = "https://dummy.test/mcp"
  RESOURCE_B = "https://other.test/mcp"
  CLIENT_REDIRECT = "https://claude.ai/callback"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.principal_model = "User"
      c.resource_uri = RESOURCE_A
      c.brand_name = "Dummy"
    end
    @user = User.create!(email: "tester@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  def register_client(name: "Claude Code", redirect_uris: [ CLIENT_REDIRECT ])
    post "/oauth/register", params: { client_name: name, redirect_uris: redirect_uris }
    assert_response :created
    JSON.parse(response.body)
  end

  test "discovery metadata exposes authorization + protected resource endpoints" do
    get "/.well-known/oauth-authorization-server"
    body = JSON.parse(response.body)
    assert_equal "http://www.example.com/oauth/authorize", body["authorization_endpoint"]
    assert_equal [ "S256" ], body["code_challenge_methods_supported"]
    assert_equal [ "mcp" ], body["scopes_supported"]
    # Only "none" — gem doesn't authenticate client secrets so it
    # must not advertise client_secret_post.
    assert_equal [ "none" ], body["token_endpoint_auth_methods_supported"]

    get "/.well-known/oauth-protected-resource"
    body = JSON.parse(response.body)
    assert_equal RESOURCE_A, body["resource"]
    assert_equal [ "header" ], body["bearer_methods_supported"]
    # PRM SHOULD include scopes_supported (2025-11-25 spec) so RSes
    # can echo per-tool required scopes in 403 challenges.
    assert_equal [ "mcp" ], body["scopes_supported"]
  end

  # The metadata body is derived from the request Host (issuer + all
  # endpoint URLs come from request.base_url). It MUST NOT be stored in a
  # shared cache that keys on path alone: a forged-Host request could
  # otherwise poison the cached entry and steer later clients' credential
  # flow to an attacker-controlled token_endpoint. So the responses are
  # cached privately (per client), never `public`, and key any cache on
  # Host as defense-in-depth.
  test "discovery metadata is not shared-cacheable and varies on Host" do
    %w[/.well-known/oauth-authorization-server /.well-known/oauth-protected-resource].each do |path|
      get path
      cache_control = response.headers["Cache-Control"].to_s
      assert_not_includes cache_control, "public",
        "#{path} is shared-cacheable while its body is Host-derived — cache-poisoning risk"
      assert_includes cache_control, "private", "#{path} should be privately cacheable"
      assert_includes response.headers["Vary"].to_s, "Host",
        "#{path} must Vary on Host so caches don't serve a forged-Host response cross-host"
    end
  end

  test "CORS preflight on .well-known/*" do
    process :options, "/.well-known/oauth-authorization-server", headers: { "Origin" => "https://claude.ai" }
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]

    process :options, "/.well-known/oauth-protected-resource", headers: { "Origin" => "https://claude.ai" }
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  test "DCR rejects javascript: redirect_uri" do
    post "/oauth/register", params: { client_name: "Bad", redirect_uris: [ "javascript:alert(1)" ] }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_redirect_uri", body["error"]
  end

  test "DCR rejects non-loopback http redirect_uri" do
    post "/oauth/register", params: { client_name: "Bad", redirect_uris: [ "http://attacker.test/cb" ] }
    assert_response :bad_request
    assert_equal "invalid_redirect_uri", JSON.parse(response.body)["error"]
  end

  test "DCR allows http loopback redirect_uri" do
    post "/oauth/register", params: { client_name: "Local", redirect_uris: [ "http://localhost:8080/cb" ] }
    assert_response :created
  end

  test "DCR rejects when one of multiple redirect_uris is bad" do
    post "/oauth/register", params: { client_name: "Mixed", redirect_uris: [ "https://app.test/cb", "javascript:1" ] }
    assert_response :bad_request
  end

  test "authorize matches loopback redirect_uri port-agnostically (RFC 8252)" do
    # Client registers http://localhost:9000/cb but the inbound request
    # uses an ephemeral port 54321 — must still be accepted.
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "http://localhost:54321/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    assert_response :redirect
    assert response.location.start_with?("http://localhost:54321/cb")
  end

  test "authorize still rejects loopback redirect_uri with mismatched path" do
    client = register_client(redirect_uris: [ "http://localhost:9000/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "http://localhost:9000/different/path",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
  end

  test "authorize still rejects non-loopback host even if port matches" do
    client = register_client(redirect_uris: [ "https://app.test/cb" ])
    sign_in @user

    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "https://attacker.test/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
  end

  test "DCR returns client_id + persists Client row" do
    body = register_client
    assert body["client_id"].present?
    assert_equal "Claude Code", body["client_name"]
    assert_equal [ CLIENT_REDIRECT ], body["redirect_uris"]
    assert Hitch::Client.exists?(client_id: body["client_id"])
  end

  test "happy path: register → authorize → token exchange → token usable" do
    client = register_client
    sign_in @user

    # Consent screen renders for authenticated user
    get "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :success
    assert_includes response.body, "Claude"

    # User approves
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      state: "xyz",
      resource: RESOURCE_A
    }
    assert_response :redirect
    redirect_location = response.location
    assert redirect_location.start_with?(CLIENT_REDIRECT)

    code = URI.decode_www_form(URI.parse(redirect_location).query).to_h["code"]
    assert code.present?
    assert_includes redirect_location, "state=xyz"

    # Token exchange
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier,
      resource: RESOURCE_A
    }
    assert_response :success
    body = JSON.parse(response.body)
    assert body["access_token"].present?
    assert_equal "Bearer", body["token_type"]
    assert_equal "mcp", body["scope"]

    # The minted token is bound to the configured resource (RFC 8707)
    raw_token = body["access_token"]
    record = Hitch::AccessToken.find_by_token(raw_token)
    assert record.present?
    assert record.valid_for_resource?(RESOURCE_A)
    refute record.valid_for_resource?(RESOURCE_B)
  end

  test "authorize without sign-in returns 401 when login_path unset" do
    client = register_client
    get "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :unauthorized
  end

  test "authorize rejects unregistered redirect_uri for known client" do
    client = register_client(redirect_uris: [ CLIENT_REDIRECT ])
    sign_in @user

    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "https://attacker.test/callback",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_request", body["error"]
    assert_match(/redirect_uri/, body["error_description"])
  end

  test "authorize rejects non-https redirect_uri" do
    sign_in @user
    # A non-loopback http redirect is rejected at registration (DCR), so
    # register a valid loopback client, then attempt a plain-http public
    # host at authorize — the authorize endpoint re-validates the scheme
    # independently of what the client registered.
    client = register_client(redirect_uris: [ "http://localhost:8765/cb" ])
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "http://attacker.test/callback",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body)["error"]
  end

  test "authorize allows http loopback redirect_uri for a registered client" do
    client = register_client(redirect_uris: [ "http://localhost:8765/cb" ])
    sign_in @user
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: "http://localhost:8765/cb",
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :redirect
  end

  test "authorize rejects a request with no client_id (OAuth 2.1 requires it)" do
    sign_in @user
    post "/oauth/authorize", params: {
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256"
    }
    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body)["error"]
    assert_match(/client_id/, JSON.parse(response.body)["error_description"])
  end

  test "token exchange rejects wrong PKCE verifier" do
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      code_verifier: "wrong-verifier"
    }
    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body)["error"]
  end

  test "token exchange rejects mismatched resource (RFC 8707)" do
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]

    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier,
      resource: RESOURCE_B
    }
    assert_response :bad_request
    body = JSON.parse(response.body)
    assert_equal "invalid_target", body["error"]
  end

  test "authorize rejects non-URI resource parameter (RFC 8707 absolute URI)" do
    sign_in @user
    [ "javascript:alert(1)", "not a uri", "data:text/html,<h1>x", "/relative/path", "ftp://example.com/x" ].each do |bad_resource|
      post "/oauth/authorize", params: {
        redirect_uri: CLIENT_REDIRECT,
        code_challenge: @challenge,
        code_challenge_method: "S256",
        resource: bad_resource
      }
      assert_response :bad_request, "expected reject for resource=#{bad_resource.inspect}"
      assert_equal "invalid_target", JSON.parse(response.body)["error"]
    end
  end

  test "authorize rejects resource with URL fragment (RFC 8707)" do
    sign_in @user
    post "/oauth/authorize", params: {
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: "https://app.test/mcp#fragment"
    }
    assert_response :bad_request
    assert_equal "invalid_target", JSON.parse(response.body)["error"]
  end

  test "revoke endpoint always returns 200 (RFC 7009)" do
    # Unknown token still 200
    post "/oauth/revoke", params: { token: "nonexistent" }
    assert_response :ok

    # Real token gets revoked
    client = register_client
    sign_in @user
    post "/oauth/authorize", params: {
      client_id: client["client_id"],
      redirect_uri: CLIENT_REDIRECT,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE_A
    }
    code = URI.decode_www_form(URI.parse(response.location).query).to_h["code"]
    post "/oauth/token", params: {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier
    }
    raw_token = JSON.parse(response.body)["access_token"]

    post "/oauth/revoke", params: { token: raw_token }
    assert_response :ok
    assert_nil Hitch::AccessToken.find_by_token(raw_token)
  end

  test "CORS preflight returns 204 with allowed-origin headers for claude.ai" do
    process :options, "/oauth/token", headers: { "Origin" => "https://claude.ai" }
    assert_response :no_content
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  test "CORS headers set on token endpoint when Origin allowed" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "x", code_verifier: "y" },
      headers: { "Origin" => "https://claude.ai" }
    assert_equal "https://claude.ai", response.headers["Access-Control-Allow-Origin"]
  end

  test "CORS headers not set when Origin is foreign" do
    post "/oauth/token",
      params: { grant_type: "authorization_code", code: "x", code_verifier: "y" },
      headers: { "Origin" => "https://attacker.test" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
  end
end
