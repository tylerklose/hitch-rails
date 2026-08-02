# frozen_string_literal: true

require "test_helper"
require "tmpdir"
require_relative "credential_canary_middleware"

class CredentialCanaryMiddlewareTest < ActiveSupport::TestCase
  test "records exact successful token canaries privately without changing the response" do
    Dir.mktmpdir("hitch-canary-middleware-") do |temporary|
      path = File.join(temporary, "canaries.jsonl")
      response_body = JSON.generate(access_token: "token-canary")
      app = ->(_environment) { [ 200, { "Content-Type" => "application/json" }, [ response_body ] ] }
      middleware = Hitch::Conformance::CredentialCanaryMiddleware.new(app, path: path)
      environment = Rack::MockRequest.env_for("/oauth/token", method: "POST")
      environment["RAW_POST_DATA"] = URI.encode_www_form(
        code: "code-canary",
        code_verifier: "verifier-canary"
      )

      status, headers, body = middleware.call(environment)

      assert_equal 200, status
      assert_equal "application/json", headers.fetch("Content-Type")
      assert_equal response_body, body.join
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal({
        "authorization_code" => "code-canary",
        "code_verifier" => "verifier-canary",
        "access_token" => "token-canary"
      }, JSON.parse(File.read(path)))
    end
  end

  test "capture failures disclose no credential value" do
    Dir.mktmpdir("hitch-canary-middleware-") do |temporary|
      path = File.join(temporary, "canaries.jsonl")
      app = ->(_environment) { [ 200, {}, [ JSON.generate(access_token: "token-canary") ] ] }
      middleware = Hitch::Conformance::CredentialCanaryMiddleware.new(app, path: path)
      environment = Rack::MockRequest.env_for("/oauth/token", method: "POST")
      environment["RAW_POST_DATA"] = "code=code-canary"

      error = assert_raises(RuntimeError) { middleware.call(environment) }

      assert_equal "credential canary capture failed", error.message
      refute_includes error.message, "code-canary"
      refute_includes error.message, "token-canary"
    end
  end
end
