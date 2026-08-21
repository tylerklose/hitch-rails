# frozen_string_literal: true

require "rubygems/requirement"
require "rubygems/version"

module Hitch
  module MCP
    module Internal
      class SDKAdapter
        class ResponseNormalizer
          SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"

          class << self
            def call(response:, method:, server_info:, request_id:, tool_response:)
              new(response, method, server_info, request_id, tool_response).call
            end
          end

          def initialize(response, method, server_info, request_id, tool_response)
            @response = response
            @method = method
            @server_info = server_info
            @request_id = request_id
            @tool_response = tool_response
          end

          def call
            return internal_error unless response.is_a?(Hash)

            result_present = member?(response, :result)
            error_present = member?(response, :error)
            return internal_error if result_present == error_present
            return internal_error if duplicate_member?(response, :result) || duplicate_member?(response, :error)

            error = read(response, :error)
            if error_present
              return internal_error unless error.is_a?(Hash) && read(error, :code).is_a?(Integer)

              return normalize_error
            end

            result = read(response, :result)
            return internal_error unless result.is_a?(Hash)

            normalized = {
              jsonrpc: "2.0",
              id: copy(request_id),
              result: copy(result)
            }
            result = normalized.fetch(:result)

            normalize_tool_error(result) if read(result, :isError) == true
            normalize_final_result(result)
            deep_freeze(normalized)
          end

          private

          attr_reader :response, :method, :server_info, :request_id, :tool_response

          def internal_error
            deep_freeze(
              jsonrpc: "2.0",
              id: copy(request_id),
              error: { code: -32603, message: "Internal error" }
            )
          end

          def normalize_error
            error = read(response, :error)
            code = read(error, :code)
            deep_freeze(
              jsonrpc: "2.0",
              id: copy(request_id),
              error: { code: code, message: public_error_message(code) }
            )
          end

          # Hitch owns the final wire shape on every supported SDK line rather
          # than trusting what crossed the boundary. On mcp 1.1 this also
          # papered over gaps since fixed upstream (ruby-sdk#389,
          # modelcontextprotocol#3040); on mcp >= 1.2 the SDK's own modern
          # shaping is envelope-gated and Hitch strips _meta before the SDK
          # sees it, so the shape is Hitch's job either way. resultType is
          # always "complete": multi-round-trip requests are unsupported.
          def normalize_final_result(result)
            result[:resultType] = "complete"
            normalize_discovery(result) if method == "server/discover"
            normalize_private_listing(result) if %w[server/discover tools/list].include?(method)
            normalize_server_identity(result)
          end

          def normalize_tool_error(result)
            explicit_text = ResultNormalizer.explicit_error_text(tool_response)
            result.delete(:structuredContent)
            result.delete("structuredContent")
            result.delete(:_meta)
            result.delete("_meta")
            result[:content] = [
              { type: "text", text: explicit_text || Protocol::GENERIC_TOOL_ERROR }
            ]
            result[:isError] = true
          end

          def normalize_discovery(result)
            result.delete(:serverInfo)
            result.delete("serverInfo")
            result[:supportedVersions] = [ Protocol::VERSION ]
            result[:capabilities] = { tools: {} }
          end

          def server_identity
            server_info.each_with_object({}) do |(key, value), identity|
              identity[key.to_s] = stringify(value) unless key.to_s == "instructions"
            end
          end

          def normalize_server_identity(result)
            meta = read(result, :_meta)
            meta = meta.is_a?(Hash) ? stringify(meta) : {}
            meta[SERVER_INFO_META_KEY] = server_identity
            result[:_meta] = meta
          end

          def normalize_private_listing(result)
            result[:ttlMs] = 0
            result[:cacheScope] = "private"
          end

          def public_error_message(code)
            case code
            when -32601 then "Method not found"
            when -32602 then "Invalid params"
            when -32603 then "Internal error"
            else "Request failed"
            end
          end

          def read(hash, key)
            JsonValues.read(hash, key)
          end

          def member?(hash, key)
            hash.key?(key) || hash.key?(key.to_s)
          end

          def duplicate_member?(hash, key)
            hash.key?(key) && hash.key?(key.to_s)
          end

          def copy(value)
            JsonValues.copy(value)
          end

          def stringify(value)
            case value
            when Hash then value.to_h { |key, child| [ key.to_s, stringify(child) ] }
            when Array then value.map { |child| stringify(child) }
            when String then value.dup
            else value
            end
          end

          def deep_freeze(value)
            JsonValues.deep_freeze(value)
          end
        end

        private_constant :ResponseNormalizer
      end
    end
  end
end
