# frozen_string_literal: true

require "test_helper"

class CorsAndHostTest < ActionDispatch::IntegrationTest
  ORIGIN = "https://client.example"

  setup do
    Hitch.reset_configuration!
    Hitch.configure do |config|
      config.resource_uri = "https://canonical.example/mcp"
      config.allowed_hosts = [ "proxy.example" ]
      config.allowed_origins = [ ORIGIN ]
      config.dynamic_client_registration_enabled = true
    end
    host! "canonical.example"
  end

  teardown do
    Hitch.reset_configuration!
  end

  test "canonical and ingress-alias hosts advertise one fixed issuer" do
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    assert_equal "https://canonical.example", JSON.parse(response.body).fetch("issuer")

    host! "proxy.example"
    get "/.well-known/oauth-authorization-server"
    assert_response :success
    metadata = JSON.parse(response.body)
    assert_equal "https://canonical.example", metadata.fetch("issuer")
    %w[authorization_endpoint token_endpoint revocation_endpoint registration_endpoint].each do |field|
      assert metadata.fetch(field).start_with?("https://canonical.example/"),
        "#{field} must use the fixed canonical origin"
    end
  end

  test "invalid Host is rejected before discovery derives an attacker URL" do
    host! "attacker.example"

    get "/.well-known/oauth-authorization-server"

    assert_response :bad_request
    assert_equal "invalid_request", JSON.parse(response.body).fetch("error")
    refute_includes response.body, "attacker.example"
  end

  test "an allowed hostname with the wrong effective port is rejected" do
    host! "canonical.example:8443"

    get "/.well-known/oauth-authorization-server"

    assert_response :bad_request
    refute_includes response.body, "8443"
  end

  test "an allowed hostname with a forwarded downgrade is rejected" do
    https!(false)
    get "/.well-known/oauth-authorization-server", headers: { "X-Forwarded-Proto" => "http" }

    assert_response :bad_request
    refute_includes response.body, "http://canonical.example"
  end

  test "forwarded Host cannot replace the canonical issuer" do
    get "/.well-known/oauth-authorization-server", headers: {
      "X-Forwarded-Host" => "attacker.example",
      "X-Forwarded-Proto" => "https"
    }

    assert_response :bad_request
    refute_includes response.body, "attacker.example"
  end

  test "an IPv6 loopback resource renders one bracketed fixed authority" do
    Hitch.configuration.resource_uri = "http://[::1]:3000/mcp"
    Hitch.configuration.allowed_hosts = []
    https!(false)

    get "/.well-known/oauth-authorization-server", headers: { "Host" => "[::1]:3000" }

    assert_response :success
    assert_equal "http://[::1]:3000", JSON.parse(response.body).fetch("issuer")
  end

  test "invalid Host is rejected before registration work" do
    host! "attacker.example"

    stub_class_method(Hitch::Client, :register!, ->(**) { flunk "registration must not run" }) do
      post "/oauth/register", params: {
        client_name: "Never stored",
        redirect_uris: [ "https://client.example/callback" ]
      }, as: :json
    end

    assert_response :bad_request
  end

  test "a valid configured preflight earns 204 and only configured headers" do
    process :options, "/oauth/token", headers: {
      "Origin" => ORIGIN,
      "Access-Control-Request-Method" => "POST",
      "Access-Control-Request-Headers" => "authorization, Content-Type"
    }

    assert_response :no_content
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
    assert_equal "POST", response.headers["Access-Control-Allow-Methods"]
    assert_includes response.headers["Access-Control-Allow-Headers"], "Authorization"
    refute_includes response.headers["Access-Control-Allow-Headers"], "X-Mcp-Header"
    assert_includes response.headers["Vary"], "Origin"
    assert_includes response.headers["Vary"], "Access-Control-Request-Method"
    assert_includes response.headers["Vary"], "Access-Control-Request-Headers"
  end

  test "missing or disallowed preflight inputs do not gain CORS" do
    vectors = [
      { "Access-Control-Request-Method" => "POST" },
      { "Origin" => "https://attacker.example", "Access-Control-Request-Method" => "POST" },
      { "Origin" => ORIGIN, "Access-Control-Request-Method" => "DELETE" },
      {
        "Origin" => ORIGIN,
        "Access-Control-Request-Method" => "POST",
        "Access-Control-Request-Headers" => "X-Mcp-Header"
      }
    ]

    vectors.each do |headers|
      process :options, "/oauth/token", headers: headers
      assert_response :forbidden
      assert_nil response.headers["Access-Control-Allow-Origin"]
    end
  end

  test "OPTIONS for an unknown OAuth path remains not found" do
    process :options, "/oauth/not-an-endpoint", headers: {
      "Origin" => ORIGIN,
      "Access-Control-Request-Method" => "POST"
    }

    assert_response :not_found
  end

  test "ordinary responses vary on Origin and reflect only an allowed origin" do
    get "/.well-known/oauth-protected-resource", headers: { "Origin" => ORIGIN }
    assert_equal ORIGIN, response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Vary"], "Origin"

    get "/.well-known/oauth-protected-resource", headers: { "Origin" => "https://attacker.example" }
    assert_nil response.headers["Access-Control-Allow-Origin"]
    assert_includes response.headers["Vary"], "Origin"
  end

  test "loopback origin exception is non-production only" do
    headers = {
      "Origin" => "http://127.0.0.1:4321",
      "Access-Control-Request-Method" => "POST"
    }

    process :options, "/oauth/token", headers: headers
    assert_response :no_content

    production = ActiveSupport::EnvironmentInquirer.new("production")
    stub_class_method(Rails, :env, -> { production }) do
      process :options, "/oauth/token", headers: headers
      assert_response :forbidden
      assert_nil response.headers["Access-Control-Allow-Origin"]
    end
  end
end
