# frozen_string_literal: true

require "test_helper"

class DynamicRegistrationLimitsTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "https://client.example/callback"

  setup do
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = "https://auth.example/mcp"
      config.allowed_hosts = [ "www.example.com" ]
      config.dynamic_client_registration_enabled = true
    end
  end

  teardown { Hitch.reset_configuration! }

  test "the exact body cap is accepted and one byte over halts before model work" do
    body = registration_body_at(Hitch::RegistrationsController::MAX_REQUEST_BODY_BYTES)
    post_raw_json(body)
    assert_response :created

    lookup = ->(**) { flunk "oversized registration must not reach the model" }
    stub_class_method(Hitch::Client, :register!, lookup) do
      post_raw_json("#{body} ")
    end

    assert_response 413
    assert_equal "invalid_client_metadata", JSON.parse(response.body).fetch("error")
    assert_equal 1, Hitch::Client.count
  end

  test "DCR requires the RFC 7591 JSON media type before model work" do
    lookup = ->(**) { flunk "non-JSON registration must not reach the model" }
    stub_class_method(Hitch::Client, :register!, lookup) do
      post "/oauth/register", params: { client_name: "Form", redirect_uris: [ REDIRECT_URI ] }
    end

    assert_response :unsupported_media_type
    assert_equal 0, Hitch::Client.count
  end

  test "malformed JSON is a stable protocol error" do
    post_raw_json('{"client_name":')

    assert_response :bad_request
    assert_equal "invalid_client_metadata", JSON.parse(response.body).fetch("error")
    assert_equal 0, Hitch::Client.count
  end

  test "redirect and scalar shape violations reject rather than filter or default" do
    invalid_payloads = [
      { client_name: "Missing redirects" },
      { client_name: "Empty", redirect_uris: [] },
      { client_name: "Object", redirect_uris: { callback: REDIRECT_URI } },
      { client_name: "Mixed", redirect_uris: [ REDIRECT_URI, 7 ] },
      { client_name: "Duplicate", redirect_uris: [ REDIRECT_URI, REDIRECT_URI ] },
      { client_name: { nested: true }, redirect_uris: [ REDIRECT_URI ] },
      { client_name: "Auth", redirect_uris: [ REDIRECT_URI ], token_endpoint_auth_method: [ "none" ] },
      { client_name: "Type", redirect_uris: [ REDIRECT_URI ], application_type: { value: "native" } }
    ]

    invalid_payloads.each do |payload|
      post "/oauth/register", params: payload, as: :json
      assert_response :bad_request, "expected strict rejection for #{payload.inspect}"
      assert_equal "invalid_client_metadata", JSON.parse(response.body).fetch("error")
    end
    assert_equal 0, Hitch::Client.count
  end

  test "metadata count and byte boundaries are exact" do
    redirects = Hitch::Client::MAX_REDIRECT_URIS.times.map do |index|
      "https://client.example/callback/#{index}"
    end
    post "/oauth/register", params: {
      client_name: "n" * Hitch::Client::MAX_CLIENT_NAME_BYTES,
      redirect_uris: redirects
    }, as: :json
    assert_response :created
    assert_equal Hitch::Client::MAX_REDIRECT_URIS, JSON.parse(response.body).fetch("redirect_uris").length

    too_many = redirects + [ "https://client.example/overflow" ]
    post "/oauth/register", params: { client_name: "Count", redirect_uris: too_many }, as: :json
    assert_response :bad_request

    post "/oauth/register", params: {
      client_name: "n" * (Hitch::Client::MAX_CLIENT_NAME_BYTES + 1),
      redirect_uris: [ REDIRECT_URI ]
    }, as: :json
    assert_response :bad_request

    long_uri = "https://client.example/" + ("x" * Hitch::Client::MAX_REDIRECT_URI_BYTES)
    post "/oauth/register", params: { client_name: "URI", redirect_uris: [ long_uri ] }, as: :json
    assert_response :bad_request
    assert_equal 1, Hitch::Client.count
  end

  test "invalid redirect errors never reflect attacker URI content" do
    canary = "https://user@client.example/callback"
    post "/oauth/register", params: { client_name: "Bad URI", redirect_uris: [ canary ] }, as: :json

    assert_response :bad_request
    assert_equal "invalid_redirect_uri", JSON.parse(response.body).fetch("error")
    refute_includes response.body, canary
    assert_equal 0, Hitch::Client.count
  end

  private

  def post_raw_json(body)
    post "/oauth/register", params: body, headers: { "CONTENT_TYPE" => "application/json" }
  end

  def registration_body_at(bytes)
    payload = {
      client_name: "Boundary",
      redirect_uris: [ REDIRECT_URI ],
      ignored_padding: ""
    }
    empty = JSON.generate(payload)
    payload[:ignored_padding] = "x" * (bytes - empty.bytesize)
    JSON.generate(payload).tap { |body| assert_equal bytes, body.bytesize }
  end
end
