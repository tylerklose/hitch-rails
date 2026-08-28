# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

# Native private-use redirect URIs (RFC 8252 §7.1) are an allowlist plus a
# voucher, not a denylist. These tests pin the properties that close the
# evil://claude.ai consent-branding hole.
class NativeRedirectUriTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
  GROKBOT = "grokbot://mcp/oauth/callback"
  CURSOR = "cursor://anysphere.cursor-mcp/oauth/callback"
  GROK_CIMD = "https://grok.com/oauth/client-metadata.json"
  CURSOR_CIMD = "https://www.cursor.com/oauth/client-metadata.json"
  ATTACKER_CIMD = "https://attacker.example/oauth/client-metadata.json"

  setup do
    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.resource_uri = RESOURCE
      c.allowed_hosts = [ "www.example.com" ]
      c.brand_name = "Dummy"
      c.client_id_metadata_enabled = true
    end
    @user = User.create!(email: "native@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  def sign_in(user)
    post "/sign_in", params: { user_id: user.id }
    assert_response :success
  end

  test "CIMD grokbot from grok.com completes authorize and token exchange" do
    sign_in @user
    document = cimd(GROK_CIMD, GROKBOT, client_name: "Not The Label")

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { document }) do
      post "/oauth/authorize", params: authorize_params(GROK_CIMD, GROKBOT)
      assert_response :redirect
      assert response.location.start_with?("#{GROKBOT}?")

      code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
      post "/oauth/token", params: {
        grant_type: "authorization_code",
        code: code,
        client_id: GROK_CIMD,
        code_verifier: @verifier,
        resource: RESOURCE,
        redirect_uri: GROKBOT
      }
      assert_response :success
      assert JSON.parse(response.body)["access_token"].present?
    end
  end

  test "CIMD cursor from cursor.com completes authorize" do
    sign_in @user
    document = cimd(CURSOR_CIMD, CURSOR)

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { document }) do
      post "/oauth/authorize", params: authorize_params(CURSOR_CIMD, CURSOR)
      assert_response :redirect
      assert response.location.start_with?("#{CURSOR}?")
    end
  end

  test "an operator-registered client may use grokbot and complete token exchange" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "operator-grokbot",
      client_name: "Operator Grok",
      redirect_uris: [ GROKBOT ],
      operator_registered: true
    )
    sign_in @user

    post "/oauth/authorize", params: authorize_params(credentials.client.client_id, GROKBOT)
    assert_response :redirect
    assert response.location.start_with?("#{GROKBOT}?")

    code = URI.decode_www_form(URI.parse(response.location).query).to_h.fetch("code")
    post "/oauth/token",
      params: {
        grant_type: "authorization_code",
        code: code,
        code_verifier: @verifier,
        resource: RESOURCE,
        redirect_uri: GROKBOT
      },
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :success
    assert JSON.parse(response.body)["access_token"].present?
  end

  test "DCR cannot register grokbot or cursor" do
    [ GROKBOT, CURSOR ].each do |uri|
      post "/oauth/register", params: { client_name: "Native", redirect_uris: [ uri ] }, as: :json
      assert_response :bad_request, uri
      assert_equal "invalid_redirect_uri", JSON.parse(response.body).fetch("error")
    end
    assert_equal 0, Hitch::Client.count
  end

  test "a stuffed DCR row cannot spend a grokbot redirect at authorize" do
    client = Hitch::Client.register!(
      client_id: SecureRandom.uuid,
      client_name: "Sneaky",
      redirect_uris: [ GROKBOT ]
    )
    sign_in @user

    post "/oauth/authorize", params: authorize_params(client.client_id, GROKBOT)
    assert_response :bad_request
    assert_equal "client has no usable redirect_uris",
      JSON.parse(response.body)["error_description"]
  end

  test "evil://claude.ai is refused and never branded as Claude" do
    sign_in @user
    post "/oauth/authorize", params: authorize_params("anyone", "evil://claude.ai/callback")
    assert_response :bad_request
    assert_equal "Invalid redirect_uri", JSON.parse(response.body)["error_description"]
    refute_includes response.body, "Claude"
  end

  test "consent for an admitted native URI does not impersonate Claude" do
    Hitch.configure { |c| c.native_redirect_schemes = %w[myapp] }
    credentials = Hitch::Client.register_confidential!(
      client_id: "operator-myapp",
      client_name: "Claude",
      redirect_uris: [ "myapp://claude.ai/callback" ],
      operator_registered: true
    )
    sign_in @user

    get "/oauth/authorize", params: authorize_params(credentials.client.client_id, "myapp://claude.ai/callback")
    assert_response :success
    refute_includes response.body, "Claude"
    refute_includes response.body, "Cursor"
    refute_includes response.body, "Grok"
    assert_includes response.body, "myapp"
    refute_match(/\(\s*claude\.ai\s*\)/, response.body)
  end

  test "CIMD grokbot consent shows Grok from the document host, not mcp" do
    sign_in @user
    document = cimd(GROK_CIMD, GROKBOT, client_name: "Trusted Bank")

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { document }) do
      get "/oauth/authorize", params: authorize_params(GROK_CIMD, GROKBOT)
      assert_response :success
      assert_includes response.body, "Grok"
      refute_includes response.body, "Trusted Bank"
      refute_includes response.body, "(mcp)"
    end
  end

  test "privileged and unknown native schemes are refused at authorize" do
    sign_in @user
    [
      "intent://scan/#Intent;end",
      "chrome-extension://id/callback",
      "web+mcp://host/callback",
      "smb://server/share",
      "file://localhost/etc/passwd"
    ].each do |uri|
      post "/oauth/authorize", params: authorize_params("anyone", uri)
      assert_response :bad_request, uri
      assert_equal "Invalid redirect_uri", JSON.parse(response.body)["error_description"], uri
    end
  end

  test "CIMD from a non-voucher host cannot use grokbot" do
    sign_in @user
    hostile = cimd(ATTACKER_CIMD, GROKBOT)

    stub_class_method(Hitch::ClientIdMetadata, :resolve, ->(_id, **) { hostile }) do
      post "/oauth/authorize", params: authorize_params(ATTACKER_CIMD, GROKBOT)
      assert_response :bad_request
      assert_equal "client has no usable redirect_uris",
        JSON.parse(response.body)["error_description"]
    end
  end

  test "missing PKCE on a native authorize still fails" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "operator-pkce",
      client_name: "Native",
      redirect_uris: [ GROKBOT ],
      operator_registered: true
    )
    sign_in @user

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: credentials.client.client_id,
      redirect_uri: GROKBOT,
      resource: RESOURCE
    }
    assert_response :bad_request
    assert_match(/code_challenge/, JSON.parse(response.body)["error_description"])
  end

  private

  def cimd(client_id, redirect_uri, client_name: "Doc Client")
    Hitch::ClientIdMetadata::Document.new(
      client_id: client_id, client_name: client_name, redirect_uris: [ redirect_uri ]
    )
  end

  def authorize_params(client_id, redirect_uri)
    {
      response_type: "code",
      client_id: client_id,
      redirect_uri: redirect_uri,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource: RESOURCE
    }
  end

  def basic_header(client_id, client_secret)
    username = URI.encode_www_form_component(client_id)
    password = URI.encode_www_form_component(client_secret)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end
end
