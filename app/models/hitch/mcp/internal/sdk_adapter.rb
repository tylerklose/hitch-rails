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

          # Builds the SDK-facing tool wrapper once per registry snapshot —
          # ::MCP::Tool.define compiles the JSON schemas eagerly, which is the
          # cost this memoization exists to stop paying per tool per request.
          # The block closes over nothing request-scoped: each request routes
          # through the dispatcher its own ::MCP::Server carries in
          # server_context, so a shared wrapper can never see another
          # request's principal.
          def build_sdk_tool(name:, description:, input_schema:, output_schema: nil, annotations: nil)
            name = validate_tool_name!(name)
            ::MCP::Tool.define(
              name: name,
              description: description,
              input_schema: input_schema,
              output_schema: output_schema,
              annotations: annotations
            ) do |server_context:, **arguments|
              server_context.fetch(:hitch_dispatch).call(name, server_context, arguments)
            end
          end

          def validate_tool_name!(name)
            valid = name.is_a?(String) &&
              name.length.between?(1, MAX_TOOL_NAME_LENGTH) &&
              TOOL_NAME_PATTERN.match?(name)
            return name if valid

            raise ArgumentError,
              "tool name must be 1-#{MAX_TOOL_NAME_LENGTH} ASCII letters, digits, underscore, dot, or dash"
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

        # The server itself stays per-request on purpose: both supported SDK
        # lines bind server_context at construction (1.1.0 server.rb:179,
        # 1.2.0 server.rb:222) with no per-handle alternative, so a fresh thin
        # server is what keeps one request's principal out of another's. The
        # expensive part — schema compilation inside ::MCP::Tool.define — is
        # memoized per snapshot entry and only assembled here.
        def build_server
          # The endpoint boundary has already validated server_info against the
          # supported key set; the SDK constructor only needs symbol keywords.
          ::MCP::Server.new(
            **server_info.transform_keys(&:to_sym),
            tools: sdk_tools,
            capabilities: { tools: {} },
            server_context: { hitch_context: context, hitch_dispatch: dispatch }.freeze,
            configuration: sdk_configuration,
            ttl_ms: 0,
            cache_scope: "private"
          )
        end

        def sdk_tools
          tools.map do |definition|
            next definition.sdk_tool if definition.respond_to?(:sdk_tool)

            annotations = definition.annotations if definition.respond_to?(:annotations)
            self.class.build_sdk_tool(
              name: definition.name,
              description: definition.description,
              input_schema: definition.input_schema,
              output_schema: definition.output_schema,
              annotations: annotations
            )
          end
        end

        # Request-scoped state rides this lambda instead of the shared tool
        # wrappers: the response capture feeds ResponseNormalizer's explicit
        # tool-error text, and the name lookup resolves the wrapper's call to
        # this request's admitted definitions.
        def dispatch
          tools_by_name = tools.to_h { |definition| [ definition.name, definition ] }
          captured = @tool_responses
          lambda do |name, server_context, arguments|
            tools_by_name.fetch(name).call(server_context:, **arguments)
              .tap { |response| captured << response }
          end.freeze
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

        def deep_freeze(value)
          JsonValues.deep_freeze(value)
        end
      end
    end
  end
end
