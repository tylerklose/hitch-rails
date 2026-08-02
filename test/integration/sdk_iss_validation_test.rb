# frozen_string_literal: true

require "test_helper"
require "digest"
require "base64"
require "securerandom"

begin
  require "mcp"
rescue LoadError
  nil
end

# Drives the REAL Ruby MCP SDK client-side validator against the
# authorization response this server actually produces.
#
# Everything else about RFC 9207 here is verified against our own reading
# of the spec — that the `iss` we emit matches the `issuer` we advertise,
# byte for byte. This asserts the thing that actually matters: that the
# client which will consume it agrees. Twice this session a change was
# verified through the layer it was built on rather than the layer that
# runs for real, and both times that hid a defect.
#
# The development lock exercises
# MCP::Client::OAuth::Flow#validate_authorization_response_issuer! directly.
# The capability guard keeps a missing optional development dependency readable.
class SdkIssValidationTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
  CALLBACK = "https://claude.ai/callback"

  def self.sdk_validates_iss?
    defined?(MCP::Client::OAuth::Flow) &&
      MCP::Client::OAuth::Flow.private_method_defined?(:validate_authorization_response_issuer!)
  end

  setup do
    unless self.class.sdk_validates_iss?
      skip "mcp #{defined?(MCP::VERSION) ? MCP::VERSION : '(absent)'} does not expose issuer validation"
    end

    User.delete_all
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |c|
      c.resource_uri = RESOURCE
      c.allowed_hosts = [ "www.example.com" ]
      c.brand_name = "Dummy"
    end
    @user = User.create!(email: "sdk@test")
    @verifier = SecureRandom.urlsafe_base64(64)
    @challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false)

    # https so the server advertises the capability — RFC 9207 §2 requires
    # an https issuer, and the interesting branch of the SDK's validator
    # is keyed on that advertisement.
    https!
  end

  teardown { https!(false) }

  # The validator reads only its arguments, so a bare provider is enough
  # to reach it without standing up a real HTTP round trip.
  def validator = MCP::Client::OAuth::Flow.new(provider: Object.new)

  def validate(as_metadata:, iss:, iss_provided: true)
    validator.send(:validate_authorization_response_issuer!,
                   as_metadata: as_metadata, iss: iss, iss_provided: iss_provided)
  end

  def discovery_metadata
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    JSON.parse(response.body)
  end

  # Returns the authorization response parameters this server really
  # emits, from a real authorize round trip — not a hand-built fixture.
  def authorization_response
    post "/oauth/register", params: { client_name: "SDK", redirect_uris: [ CALLBACK ] }, as: :json
    assert_response :created
    client_id = JSON.parse(response.body)["client_id"]

    post "/sign_in", params: { user_id: @user.id }
    assert_response :success

    post "/oauth/authorize", params: {
      response_type: "code",
      client_id: client_id, redirect_uri: CALLBACK,
      code_challenge: @challenge, code_challenge_method: "S256",
      state: "xyz", resource: RESOURCE
    }
    assert_response :redirect
    URI.decode_www_form(URI.parse(response.location).query).to_h
  end

  test "the SDK accepts the iss this server emits" do
    metadata = discovery_metadata
    assert_equal true, metadata["authorization_response_iss_parameter_supported"]

    returned = authorization_response
    assert_equal metadata["issuer"], returned["iss"]

    # The assertion that matters: no raise.
    assert_nil validate(as_metadata: metadata, iss: returned["iss"])
  end

  test "the SDK rejects an iss that does not match the advertised issuer" do
    metadata = discovery_metadata

    error = assert_raises(MCP::Client::OAuth::Flow::AuthorizationError) do
      validate(as_metadata: metadata, iss: "https://attacker-as.example")
    end
    assert_match(/iss/i, error.message)
  end

  # The reason the advertisement and the parameter must ship together:
  # advertising support and then omitting `iss` is a hard failure at the
  # client, not a soft one. This is that branch, in the SDK's own code.
  test "the SDK rejects a missing iss once support is advertised" do
    metadata = discovery_metadata
    assert_equal true, metadata["authorization_response_iss_parameter_supported"]

    assert_raises(MCP::Client::OAuth::Flow::AuthorizationError) do
      validate(as_metadata: metadata, iss: nil)
    end
  end

  # And the reason withholding the advertisement over plain http is safe
  # rather than merely quiet: unadvertised plus absent is the one
  # combination the SDK lets through.
  test "the SDK proceeds when iss is absent and unadvertised" do
    Hitch.configuration.resource_uri = "http://127.0.0.1/mcp"
    host! "127.0.0.1"
    https!(false)
    metadata = discovery_metadata
    assert_equal false, metadata["authorization_response_iss_parameter_supported"]

    assert_nil validate(as_metadata: metadata, iss: nil)
  end
end
