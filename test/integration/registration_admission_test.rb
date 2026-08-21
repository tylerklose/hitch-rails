# frozen_string_literal: true

require "test_helper"

class RegistrationAdmissionTest < ActionDispatch::IntegrationTest
  REDIRECT_URI = "https://client.example/callback"

  class FailingStore < ActiveSupport::Cache::MemoryStore
    def increment(*, **)
      raise "unavailable"
    end
  end

  setup do
    Hitch::Client.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = "https://auth.example/mcp"
      config.allowed_hosts = [ "www.example.com" ]
      config.allowed_origins = [ "https://allowed.example" ]
      config.dynamic_client_registration_enabled = true
    end
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "strict admission parses accepted JSON once and Rails reuses it" do
    original_parsers = ActionDispatch::Request.parameter_parsers
    rails_json_parser = lambda do |_body|
      flunk "Rails must reuse the parameters installed by registration admission"
    end
    ActionDispatch::Request.parameter_parsers = original_parsers.merge(json: rails_json_parser)

    post_json(valid_registration)

    assert_response :created
    assert_equal 1, Hitch::Client.count
  ensure
    ActionDispatch::Request.parameter_parsers = original_parsers
  end

  test "duplicate JSON names are rejected before Rails instrumentation or model work" do
    raw = <<~JSON.delete("\n")
      {
        "client_name":"Duplicate auth method",
        "redirect_uris":["#{REDIRECT_URI}"],
        "token_endpoint_auth_method":"client_secret_basic",
        "token_endpoint_auth_method":"none"
      }
    JSON

    events = processing_events do
      post_json(raw)
    end

    assert_response :bad_request
    assert_equal "invalid_client_metadata", JSON.parse(response.body).fetch("error")
    assert_empty events
    assert_equal 0, Hitch::Client.count
  end

  test "a failing registration quota wins before malformed JSON can be parsed" do
    Hitch.configuration.dynamic_client_registration_rate_store = FailingStore.new

    events = processing_events do
      post_json('{"client_name":')
    end

    assert_response :service_unavailable
    assert_equal "temporarily_unavailable", JSON.parse(response.body).fetch("error")
    assert_empty events
    assert_equal 0, Hitch::Client.count
  end

  test "media type and body cap reject before Rails instrumentation" do
    form_events = processing_events do
      post "/oauth/register", params: {
        client_name: "Form",
        redirect_uris: [ REDIRECT_URI ]
      }
    end
    assert_response :unsupported_media_type
    assert_empty form_events

    oversized = "{" + ("x" * Hitch::RegistrationsController::MAX_REQUEST_BODY_BYTES)
    body_events = processing_events do
      post_json(oversized)
    end
    assert_response :content_too_large
    assert_empty body_events
    assert_equal 0, Hitch::Client.count
  end

  test "accepted short-reading Rack-spec input is read through EOF and reused by registration" do
    raw = valid_registration
    input = NonRewindableInput.new(raw, max_chunk_size: 7)

    response = call_app_with_input(
      path: "/oauth/register",
      input: input,
      content_type: "application/json"
    )

    assert_equal 201, response.status
    assert_equal "none", JSON.parse(response.body).fetch("token_endpoint_auth_method")
    assert_equal raw.bytesize, input.bytes_read
    assert_operator input.read_calls.length, :>, 2
    assert_equal [ Hitch::RegistrationsController::MAX_REQUEST_BODY_BYTES + 1 ], input.read_calls.first
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_equal "no-cache", response.headers["Pragma"]
  end

  test "invalid Host wins before body read and early rejection keeps CORS" do
    input = NonRewindableInput.new(valid_registration)
    response = call_app_with_input(
      path: "/oauth/register",
      input: input,
      content_type: "application/json",
      host: "attacker.example",
      headers: { "HTTP_ORIGIN" => "https://allowed.example" }
    )

    assert_equal 400, response.status
    assert_empty input.read_calls
    assert_equal "https://allowed.example", response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Vary"], "Origin"
  end

  private

  def valid_registration
    JSON.generate(
      client_name: "Strict client",
      redirect_uris: [ REDIRECT_URI ],
      token_endpoint_auth_method: "none"
    )
  end

  def post_json(body)
    post "/oauth/register", params: body, headers: { "CONTENT_TYPE" => "application/json" }
  end

  def processing_events
    events = []
    subscriber = ->(event) { events << event }
    ActiveSupport::Notifications.subscribed(subscriber, "start_processing.action_controller") do
      yield
    end
    events
  end
end
