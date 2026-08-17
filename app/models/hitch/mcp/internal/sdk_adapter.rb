# frozen_string_literal: true

require "mcp"

module Hitch
  module MCP
    module Internal
      class SDKAdapter
        SUPPORTED_METHODS = %w[server/discover tools/list tools/call].freeze
        STRUCTURAL_PARAMS = {
          "server/discover" => [],
          "tools/list" => %w[cursor],
          "tools/call" => %w[name arguments]
        }.freeze
        MAX_TOOL_NAME_LENGTH = 64
        TOOL_NAME_PATTERN = /\A[A-Za-z0-9_.-]+\z/
        SDK_REQUEST_ID = "hitch_request"

        class << self
          def call(**arguments)
            new(**arguments).call
          end
        end

        def initialize(verified_request:, tools:, context:, server_info:)
          @request = copy_hash(verified_request)
          @tools = tools.dup.freeze
          @context = context
          @server_info = copy_hash(server_info)
          @tool_responses = []
        end

        def call
          return method_not_found unless SUPPORTED_METHODS.include?(request_method)
          return invalid_params if reserved_server_context?

          response = build_server.handle(structural_request)
          ResponseNormalizer.call(
            response: response,
            method: request_method,
            server_info: server_info,
            request_id: read(request, "id"),
            tool_response: @tool_responses.last
          )
        end

        private

        attr_reader :request, :tools, :context, :server_info

        def request_method
          read(request, "method")
        end

        def build_server
          # The endpoint boundary has already validated server_info against the
          # supported key set; the SDK constructor only needs symbol keywords.
          ::MCP::Server.new(
            **server_info.transform_keys(&:to_sym),
            tools: build_tools,
            capabilities: { tools: {} },
            server_context: { hitch_context: context }.freeze,
            configuration: sdk_configuration,
            ttl_ms: 0,
            cache_scope: "private"
          )
        end

        def build_tools
          # The SDK rebinds self inside this block (define_singleton_method),
          # so the response capture rides a closed-over local.
          captured = @tool_responses
          tools.map do |definition|
            name = validate_tool_name!(definition.name)
            annotations = definition.annotations if definition.respond_to?(:annotations)

            ::MCP::Tool.define(
              name: name,
              description: definition.description,
              input_schema: definition.input_schema,
              output_schema: definition.output_schema,
              annotations: annotations
            ) do |server_context:, **arguments|
              definition.call(server_context:, **arguments).tap { |response| captured << response }
            end
          end
        end

        # No protocol_version pin: on the modern wire every request carries its
        # version, and both supported SDK lines default their stable version to
        # 2026-07-28 — the value we used to pin. mcp 1.2.0 rejects pinning a
        # modern version outright.
        def sdk_configuration
          ::MCP::Configuration.new(
            validate_tool_call_arguments: true,
            validate_tool_call_results: true,
            exception_reporter: ->(_exception, _data) { },
            around_request: ->(_data, &handler) { handler.call },
            instrumentation_callback: ->(_data) { }
          )
        end

        def structural_request
          params = read(request, "params")
          structural_params = STRUCTURAL_PARAMS.fetch(request_method).each_with_object({}) do |key, result|
            copy_fixed_key(result, params, key)
          end

          # SDK 1.1 merges request _meta into a Hash server_context. Hitch has
          # already verified and copied that metadata into its own Context, so it
          # must not cross this boundary and dilute the one authority wrapper.

          deep_freeze(
            jsonrpc: read(request, "jsonrpc"),
            id: SDK_REQUEST_ID,
            method: request_method,
            params: structural_params
          )
        end

        def reserved_server_context?
          return false unless request_method == "tools/call"

          arguments = read(read(request, "params"), "arguments")
          arguments.instance_of?(Hash) && arguments.key?("server_context")
        end

        def method_not_found
          protocol_error(-32601, "Method not found")
        end

        def invalid_params
          protocol_error(-32602, "Invalid params")
        end

        def protocol_error(code, message)
          {
            jsonrpc: "2.0",
            id: read(request, "id"),
            error: { code: code, message: message }
          }.then { |response| deep_freeze(response) }
        end

        def copy_fixed_key(target, source, key)
          return unless source.is_a?(Hash)

          if source.key?(key)
            target[key.to_sym] = JsonValues.deep_string_copy_and_freeze(source[key])
          elsif source.key?(key.to_sym)
            target[key.to_sym] = JsonValues.deep_string_copy_and_freeze(source[key.to_sym])
          end
        end

        def read(hash, key)
          JsonValues.read(hash, key)
        end

        def copy_hash(value)
          raise ArgumentError, "verified request and server info must be Hash values" unless value.is_a?(Hash)

          JsonValues.deep_string_copy_and_freeze(value)
        end

        def validate_tool_name!(name)
          valid = name.is_a?(String) &&
            name.length.between?(1, MAX_TOOL_NAME_LENGTH) &&
            TOOL_NAME_PATTERN.match?(name)
          return name if valid

          raise ArgumentError,
            "tool name must be 1-#{MAX_TOOL_NAME_LENGTH} ASCII letters, digits, underscore, dot, or dash"
        end

        def deep_freeze(value)
          JsonValues.deep_freeze(value)
        end
      end
    end
  end
end
