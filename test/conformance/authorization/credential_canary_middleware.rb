# frozen_string_literal: true

require "json"
require "uri"

module Hitch
  module Conformance
    # Disposable-host middleware that records the exact successful token-flow
    # credentials in a private, temporary canary file. It observes the request
    # and response only after Hitch has processed them, so it cannot become an
    # earlier request-body reader. The harness uses these values solely to
    # prove the Rails log contains none of them, then destroys the fixture.
    class CredentialCanaryMiddleware
      def initialize(app, path:)
        @app = app
        @path = path
      end

      def call(environment)
        status, headers, body = @app.call(environment)
        return [ status, headers, body ] unless successful_token_exchange?(environment, status)

        parts = []
        body.each { |part| parts << part.to_s }
        body.close if body.respond_to?(:close)
        record_canaries!(environment, parts.join)
        [ status, headers, parts ]
      end

      private

      def successful_token_exchange?(environment, status)
        environment[Rack::REQUEST_METHOD] == "POST" &&
          Rack::Utils.clean_path_info(environment[Rack::PATH_INFO]) == "/oauth/token" &&
          status.to_i == 200
      end

      def record_canaries!(environment, response_body)
        request_values = URI.decode_www_form(environment.fetch("RAW_POST_DATA", "")).to_h
        response_values = JSON.parse(response_body)
        canaries = {
          authorization_code: request_values.fetch("code"),
          code_verifier: request_values.fetch("code_verifier"),
          access_token: response_values.fetch("access_token")
        }
        raise "credential canary capture failed" if canaries.values.any?(&:empty?)

        File.open(@path, File::WRONLY | File::APPEND | File::CREAT, 0o600) do |file|
          file.flock(File::LOCK_EX)
          file.puts(JSON.generate(canaries))
          file.flush
          file.flock(File::LOCK_UN)
        end
      rescue KeyError, JSON::ParserError, ArgumentError
        raise "credential canary capture failed"
      end
    end
  end
end
