# frozen_string_literal: true

require "test_helper"

class OauthFormAdmissionTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = RESOURCE
      config.allowed_hosts = [ "www.example.com" ]
      config.allowed_origins = [ "https://allowed.example" ]
    end
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "token instrumentation sees no credential body while the action reads bounded raw form" do
    verifier = "a" * 43
    payloads = processing_payloads do
      post "/oauth/token", params: {
        grant_type: "authorization_code",
        code: "unknown-code",
        client_id: "public-client",
        code_verifier: verifier,
        resource: RESOURCE
      }
    end

    assert_response :bad_request
    assert_equal "invalid_grant", JSON.parse(response.body).fetch("error"), response.body
    assert_equal 1, payloads.length
    refute_includes payloads.first.fetch(:params).keys.map(&:to_s), "code"
    refute_includes payloads.first.fetch(:params).keys.map(&:to_s), "code_verifier"
  end

  test "revocation instrumentation sees no token while the action reads bounded raw form" do
    seen = []
    lookup = ->(token) { seen << token; nil }

    payloads = stub_class_method(Hitch::AccessToken, :find_by_token, lookup) do
      processing_payloads do
        post "/oauth/revoke", params: { token: "opaque-token" }
      end
    end

    assert_response :ok
    assert_equal [ "opaque-token" ], seen
    assert_equal 1, payloads.length
    refute_includes payloads.first.fetch(:params).keys.map(&:to_s), "token"
  end

  test "oversized OAuth forms halt before controller instrumentation" do
    token_events = processing_payloads do
      post "/oauth/token", params: "code_verifier=#{'a' * 20_000}",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end
    assert_response :content_too_large
    assert_empty token_events

    revoke_events = processing_payloads do
      post "/oauth/revoke", params: "token=#{'a' * 20_000}",
        headers: { "CONTENT_TYPE" => "application/x-www-form-urlencoded" }
    end
    assert_response :ok
    assert_empty revoke_events
  end

  test "accepted Rack-spec input is read through EOF and replayed to the token action" do
    raw = URI.encode_www_form(
      grant_type: "authorization_code",
      code: "unknown-code",
      client_id: "public-client",
      code_verifier: "a" * 43,
      resource: RESOURCE
    )
    input = NonRewindableInput.new(raw)

    response = call_app_with_input(
      path: "/oauth/token",
      input: input,
      content_type: "application/x-www-form-urlencoded"
    )

    assert_equal 400, response.status
    assert_equal raw.bytesize, input.bytes_read
    assert_operator input.read_calls.length, :>=, 2
    assert_equal [ Hitch::TokensController::MAX_REQUEST_BODY_BYTES + 1 ], input.read_calls.first
    assert_equal "invalid_grant", JSON.parse(response.body).fetch("error"), response.body
  end

  test "short-reading Rack input cannot hide a duplicate parameter" do
    raw = "token=good&token=bad"
    input = NonRewindableInput.new(raw, max_chunk_size: 10)
    seen = []

    response = stub_class_method(Hitch::AccessToken, :find_by_token, ->(token) { seen << token }) do
      call_app_with_input(
        path: "/oauth/revoke",
        input: input,
        content_type: "application/x-www-form-urlencoded"
      )
    end

    assert_equal 200, response.status
    assert_empty seen
    assert_equal raw.bytesize, input.bytes_read
    assert_operator input.read_calls.length, :>=, 3
  end

  test "short-reading oversized input stops at the cap sentinel" do
    maximum = Hitch::TokensController::MAX_REQUEST_BODY_BYTES
    input = NonRewindableInput.new("code=#{'a' * 20_000}", max_chunk_size: 1024)

    response = call_app_with_input(
      path: "/oauth/token",
      input: input,
      content_type: "application/x-www-form-urlencoded"
    )

    assert_equal 413, response.status
    assert_equal maximum + 1, input.bytes_read
  end

  test "Rails path variants reach the same pre-parser body cap" do
    [ "/oauth/token.json", "/oauth/token/", "/oauth//token", "/oauth/token//" ].each do |path|
      input = NonRewindableInput.new("code=#{'a' * 20_000}", max_chunk_size: 1024)

      response = call_app_with_input(
        path: path,
        input: input,
        content_type: "application/x-www-form-urlencoded"
      )

      assert_equal 413, response.status, path
      assert_equal Hitch::TokensController::MAX_REQUEST_BODY_BYTES + 1, input.bytes_read, path
    end
  end

  test "a host route shadowing the token path retains its ordinary form body" do
    [ "/oauth/token", "/oauth/./token" ].each do |path|
      input = NonRewindableInput.new("ordinary=value")

      response = call_app_with_input(
        path: path,
        input: input,
        content_type: "application/x-www-form-urlencoded",
        headers: { "HTTP_X_HITCH_HOST_SHADOW" => "1" }
      )

      assert_equal 200, response.status, path
      assert_equal({ "ordinary" => "value" }, JSON.parse(response.body), path)
    end
  end

  test "early OAuth rejection keeps allowed CORS without controller instrumentation" do
    events = processing_payloads do
      post "/oauth/token", params: "code=#{'a' * 20_000}", headers: {
        "CONTENT_TYPE" => "application/x-www-form-urlencoded",
        "Origin" => "https://allowed.example"
      }
    end

    assert_response :content_too_large
    assert_equal "https://allowed.example", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Vary"], "Origin"
    assert_empty events

    post "/oauth/token", params: "code=#{'a' * 20_000}", headers: {
      "CONTENT_TYPE" => "application/x-www-form-urlencoded",
      "Origin" => "https://denied.example"
    }
    assert_nil response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Vary"], "Origin"
  end

  private

  def processing_payloads
    payloads = []
    subscriber = ->(event) { payloads << event.payload }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      yield
    end
    payloads
  end
end
