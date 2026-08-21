# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "securerandom"
require "yaml"

class ResourceAwareGrantsProfileTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://www.example.com/mcp"
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
    @user = User.create!(email: "auth-conformance@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)
  end

  test "public client sends its ID and the same canonical resource" do
    client = Hitch::Client.register!(client_id: "public", client_name: "Public", redirect_uris: [ REDIRECT_URI ])
    code = mint_code(client)

    post "/oauth/token", params: token_form(code, client_id: client.client_id)

    assert_response :success
    assert JSON.parse(response.body).fetch("access_token").present?
  end

  test "reviewed extension is an exact four-file delta from the pinned runner" do
    profile = YAML.safe_load_file(File.expand_path("profile.yml", __dir__))
    extension = profile.fetch("reviewed_extension")
    patch_path = File.expand_path("../../../#{extension.fetch('patch')}", __dir__)
    patch = File.read(patch_path)

    assert_equal extension.fetch("patch_sha256"), Digest::SHA256.file(patch_path).hexdigest
    assert_equal %w[
      src/index.ts
      src/scenarios/authorization-server/authorization-code-grant.test.ts
      src/scenarios/authorization-server/authorization-code-grant.ts
      src/schemas.ts
    ], patch.scan(%r{^diff --git a/(\S+) b/}).flatten
    assert_equal "reviewed_resource_indicator_extension", extension.fetch("evidence_class")
  end

  test "confidential client authenticates only with client_secret_basic" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "confidential",
      client_name: "Confidential",
      redirect_uris: [ REDIRECT_URI ]
    )
    code = mint_code(credentials.client)

    post "/oauth/token",
      params: token_form(code),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)

    assert_response :success
  end

  test "resource and confidential authentication failures leave the code correctable" do
    credentials = Hitch::Client.register_confidential!(
      client_id: "correctable",
      client_name: "Correctable",
      redirect_uris: [ REDIRECT_URI ]
    )
    code = mint_code(credentials.client)

    post "/oauth/token",
      params: token_form(code),
      headers: basic_header(credentials.client.client_id, "wrong-secret")
    assert_response :unauthorized
    assert_equal "invalid_client", JSON.parse(response.body).fetch("error")
    assert authorization_code_pending?(code)

    post "/oauth/token",
      params: token_form(code, resource: "https://other.example/mcp"),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :bad_request
    assert_equal "invalid_target", JSON.parse(response.body).fetch("error")
    assert authorization_code_pending?(code)

    post "/oauth/token",
      params: token_form(code),
      headers: basic_header(credentials.client.client_id, credentials.client_secret)
    assert_response :success
  end

  private

  def mint_code(client)
    Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: client.client_id,
      client_name: client.client_name,
      code_challenge: @challenge,
      code_challenge_method: "S256",
      resource_uri: RESOURCE
    ).raw_authorization_code
  end

  def token_form(code, **overrides)
    {
      grant_type: "authorization_code",
      code: code,
      code_verifier: @verifier,
      resource: RESOURCE
    }.merge(overrides)
  end

  def basic_header(client_id, secret)
    username = URI.encode_www_form_component(client_id)
    password = URI.encode_www_form_component(secret)
    { "Authorization" => "Basic #{Base64.strict_encode64("#{username}:#{password}")}" }
  end
end
