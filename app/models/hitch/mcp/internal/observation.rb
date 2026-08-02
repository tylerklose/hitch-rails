# frozen_string_literal: true

require "json"
require "openssl"
require "securerandom"

module Hitch
  module MCP
    module Internal
      # Request-local structural telemetry. The state never crosses the public
      # Context or SDK server_context boundary, and publication temporarily
      # detaches it so hostile subscribers cannot recursively observe their own
      # work as part of the request.
      class Observation
        REQUEST_EVENT = "request.hitch_mcp"
        INVOCATION_EVENT = "invocation.hitch_mcp"
        IDENTITY_SALT = "hitch/mcp/observation/v1"
        CURRENT_REQUEST_KEY = :hitch_mcp_observation_request
        TOOL_NAME_PATTERN = /\A[A-Za-z0-9_.-]{1,64}\z/
        PRINCIPAL_TYPE_PATTERN = /\A[A-Za-z_][A-Za-z0-9_:]{0,254}\z/
        MAX_IDENTITY_BYTES = 2_048
        PROTOCOL_OUTCOMES = {
          -32_700 => "parse_error",
          -32_600 => "invalid_request",
          -32_601 => "method_not_found",
          -32_602 => "invalid_params",
          -32_603 => "internal_error",
          -32_020 => "header_mismatch",
          -32_022 => "unsupported_protocol"
        }.freeze
        HTTP_OUTCOMES = {
          200 => "complete",
          400 => "bad_request",
          401 => "unauthorized",
          403 => "forbidden",
          404 => "not_found",
          405 => "method_not_allowed",
          406 => "not_acceptable",
          413 => "request_too_large",
          415 => "unsupported_media_type",
          429 => "rate_limited",
          503 => "service_unavailable"
        }.freeze
        HTTP_TERMINAL_OUTCOMES = [ 406, 413, 415 ].freeze

        class ReportedFailure < StandardError
          def initialize
            super("Hitch MCP observation delivery failed")
          end
        end

        class RequestState
          attr_reader :request_id

          def initialize(clock: Observation.__send__(:monotonic_time), request_id: SecureRandom.hex(16))
            @clock = clock
            @started_at = clock.call
            @request_id = request_id.to_s.dup.freeze
            @method = nil
            @tool_name = nil
            @principal_type = nil
            @principal_key = nil
            @client_key = nil
            @protocol_code = nil
            @request_bytes = 0
            @finished = false
          end

          def authenticated!(principal:, client_id:)
            principal_type, principal_key, client_key = Observation.__send__(
              :identity_keys,
              principal:,
              client_id:
            )
            @principal_type = principal_type
            @principal_key = principal_key
            @client_key = client_key
            nil
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, REQUEST_EVENT, "identity")
            nil
          end

          def request_bytes!(value)
            @request_bytes = value if value.is_a?(Integer) && value >= 0
            nil
          end

          def verified!(request)
            method = Observation.__send__(:read, request, "method")
            @method = method.dup.freeze if %w[server/discover tools/list tools/call].include?(method)
            nil
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, REQUEST_EVENT, "verified_request")
            nil
          end

          def tool_resolved!(name)
            @tool_name = name.dup.freeze if name.is_a?(String) && TOOL_NAME_PATTERN.match?(name)
            nil
          end

          def protocol_response!(response)
            error = Observation.__send__(:read, response, "error")
            code = Observation.__send__(:read, error, "code")
            @protocol_code = code if code.is_a?(Integer)
            nil
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, REQUEST_EVENT, "protocol_response")
            nil
          end

          def start_invocation(tool_name:)
            return if @finished
            return unless tool_name.is_a?(String) && TOOL_NAME_PATTERN.match?(tool_name)

            InvocationState.new(request_id:, tool_name:, clock: @clock)
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, INVOCATION_EVENT, "invocation_start")
            nil
          end

          def finish!(response:)
            return if @finished

            @finished = true
            http_status = response.status.to_i
            payload = {
              schema_version: 1,
              request_id:,
              method: @method,
              tool_name: @tool_name,
              principal_type: @principal_type,
              principal_key: @principal_key,
              client_key: @client_key,
              http_status:,
              protocol_code: @protocol_code,
              outcome: outcome(http_status),
              request_bytes: @request_bytes,
              response_bytes: Observation.__send__(:response_bytes, response),
              duration_ms: duration_ms
            }.freeze
            Observation.__send__(:publish, REQUEST_EVENT, payload)
            nil
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, REQUEST_EVENT, "request_finish")
            nil
          end

          private

          def outcome(http_status)
            return HTTP_OUTCOMES.fetch(http_status) if HTTP_TERMINAL_OUTCOMES.include?(http_status)

            PROTOCOL_OUTCOMES.fetch(@protocol_code) do
              HTTP_OUTCOMES.fetch(http_status, "http_error")
            end
          end

          def duration_ms
            [ ((@clock.call - @started_at) * 1_000).round(3), 0.0 ].max
          end
        end

        class InvocationState
          def initialize(request_id:, tool_name:, clock:)
            @request_id = request_id
            @tool_name = tool_name.dup.freeze
            @clock = clock
            @started_at = clock.call
            @argument_policy = "not_reached"
            @executed = false
            @result_category = "generic_error"
            @finished = false
          end

          def argument_policy_allowed!
            @argument_policy = "allowed"
            nil
          end

          def execution_started!
            @executed = true
            nil
          end

          def result_normalized!(kind:)
            @result_category = kind == :error ? "explicit_error" : "success"
            nil
          end

          def failed!(phase:, expected_denial:)
            if phase == :authorization
              @argument_policy = expected_denial ? "denied" : "failed"
            end
            @result_category = "generic_error"
            nil
          end

          def finish!
            return if @finished

            @finished = true
            payload = {
              schema_version: 1,
              request_id: @request_id,
              tool_name: @tool_name,
              availability: "available",
              argument_policy: @argument_policy,
              executed: @executed,
              result_category: @result_category,
              duration_ms: duration_ms
            }.freeze
            Observation.__send__(:publish, INVOCATION_EVENT, payload)
            nil
          rescue StandardError, SystemStackError
            Observation.__send__(:report_failure, INVOCATION_EVENT, "invocation_finish")
            nil
          end

          private

          def duration_ms
            [ ((@clock.call - @started_at) * 1_000).round(3), 0.0 ].max
          end
        end

        class << self
          def activate_request
            previous = ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY]
            state = RequestState.new
            ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY] = state
            [ state, previous ].freeze
          rescue StandardError, SystemStackError
            report_failure(REQUEST_EVENT, "request_start")
            [ nil, previous ].freeze
          end

          def deactivate_request(activation)
            previous = activation&.fetch(1, nil)
            if previous
              ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY] = previous
            else
              ActiveSupport::IsolatedExecutionState.delete(CURRENT_REQUEST_KEY)
            end
            nil
          rescue StandardError, SystemStackError
            report_failure(REQUEST_EVENT, "request_cleanup")
            nil
          end

          def start_invocation(tool_name:)
            current_request&.start_invocation(tool_name:)
          rescue StandardError, SystemStackError
            report_failure(INVOCATION_EVENT, "invocation_start")
            nil
          end

          private

          def current_request
            ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY]
          end

          def publish(event_name, payload)
            previous = ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY]
            ActiveSupport::IsolatedExecutionState.delete(CURRENT_REQUEST_KEY)
            ActiveSupport::Notifications.instrument(event_name, payload)
          rescue StandardError, SystemStackError
            report_failure(event_name, "subscriber")
            nil
          ensure
            if previous
              ActiveSupport::IsolatedExecutionState[CURRENT_REQUEST_KEY] = previous
            else
              ActiveSupport::IsolatedExecutionState.delete(CURRENT_REQUEST_KEY)
            end
          end

          def identity_keys(principal:, client_id:, key_generator: Rails.application.key_generator)
            record_class = principal.class.respond_to?(:base_class) ? principal.class.base_class : principal.class
            principal_type = record_class.name
            unless principal_type.is_a?(String) && PRINCIPAL_TYPE_PATTERN.match?(principal_type)
              raise ArgumentError, "MCP observation principal type is invalid"
            end

            principal_id = identity_component(principal.id.to_s)
            client = identity_component(client_id)
            secret = key_generator.generate_key(IDENTITY_SALT, 32)
            unless secret.is_a?(String) && secret.bytesize == 32
              raise ArgumentError, "MCP observation key is unavailable"
            end

            principal_key = hmac(secret, JSON.generate([ "principal", principal_type, principal_id ]))
            client_key = hmac(secret, JSON.generate([ "client", client ]))
            [ principal_type.dup.freeze, principal_key, client_key ].freeze
          end

          def identity_component(value)
            unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
                value.bytesize <= MAX_IDENTITY_BYTES
              raise ArgumentError, "MCP observation identity is invalid"
            end

            value
          end

          def hmac(secret, value)
            OpenSSL::HMAC.hexdigest("SHA256", secret, value).freeze
          end

          def read(hash, key)
            return unless hash.is_a?(Hash)

            hash.key?(key) ? hash[key] : hash[key.to_sym]
          end

          def response_bytes(response)
            body = response.body
            return body.bytesize if body.is_a?(String)
            return 0 if body.nil?

            Array(body).sum { |part| part.to_s.bytesize }
          end

          def monotonic_time
            -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
          end

          def report_failure(event_name, category)
            return unless Rails.respond_to?(:error)

            failure = ReportedFailure.new
            failure.set_backtrace(caller(1, 8))
            failure.freeze
            Rails.error.report(
              failure,
              handled: true,
              severity: :error,
              context: {
                hitch_mcp_category: "observation_#{category}".freeze,
                hitch_mcp_event: event_name.dup.freeze
              }.freeze,
              source: "hitch.mcp.observation"
            )
            nil
          rescue StandardError, SystemStackError
            nil
          end
        end

        private_constant :ReportedFailure, :RequestState, :InvocationState,
          :REQUEST_EVENT, :INVOCATION_EVENT, :IDENTITY_SALT,
          :CURRENT_REQUEST_KEY, :TOOL_NAME_PATTERN, :PRINCIPAL_TYPE_PATTERN,
          :MAX_IDENTITY_BYTES, :PROTOCOL_OUTCOMES, :HTTP_OUTCOMES,
          :HTTP_TERMINAL_OUTCOMES
      end
    end
  end
end
