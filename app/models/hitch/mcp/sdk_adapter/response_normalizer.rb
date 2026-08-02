# frozen_string_literal: true

require "rubygems/requirement"
require "rubygems/version"

module Hitch
  module MCP
    class SDKAdapter
      class ResponseNormalizer
        PROTOCOL_VERSION = "2026-07-28"
        SERVER_INFO_META_KEY = "io.modelcontextprotocol/serverInfo"
        GENERIC_TOOL_ERROR = "Tool execution failed"
        SDK_1_1_GAPS = Gem::Requirement.new(">= 1.1.0", "< 1.2.0")
        UPSTREAM_ISSUES = {
          final_discovery: "https://github.com/modelcontextprotocol/ruby-sdk/issues/389",
          final_result_fields: "https://github.com/modelcontextprotocol/modelcontextprotocol/issues/3040"
        }.freeze

        class << self
          def call(response:, method:, server_info:)
            new(response, method, server_info).call
          end
        end

        def initialize(response, method, server_info)
          @response = response
          @method = method
          @server_info = server_info
        end

        def call
          return unless response
          return normalize_error if read(response, :error)

          normalized = copy(response)
          result = read(normalized, :result)
          return deep_freeze(normalized) unless result.is_a?(Hash)

          normalize_sdk_1_1_gaps(result) if sdk_1_1_gaps?
          normalize_tool_error(result) if read(result, :isError) == true
          deep_freeze(normalized)
        end

        private

        attr_reader :response, :method, :server_info

        def normalize_error
          error = read(response, :error)
          code = read(error, :code)
          deep_freeze(
            jsonrpc: read(response, :jsonrpc) || "2.0",
            id: read(response, :id),
            error: { code: code, message: public_error_message(code) }
          )
        end

        def normalize_sdk_1_1_gaps(result)
          result[:resultType] = "complete"
          normalize_discovery(result) if method == "server/discover"
          normalize_private_listing(result) if %w[server/discover tools/list].include?(method)
        end

        def normalize_tool_error(result)
          result.delete(:structuredContent)
          result.delete("structuredContent")
          result.delete(:_meta)
          result.delete("_meta")
          result[:content] = [ { type: "text", text: GENERIC_TOOL_ERROR } ]
          result[:isError] = true
        end

        def normalize_discovery(result)
          result.delete(:serverInfo)
          result.delete("serverInfo")
          result[:supportedVersions] = [ PROTOCOL_VERSION ]
          result[:capabilities] = { tools: {} }

          meta = read(result, :_meta)
          meta = meta.is_a?(Hash) ? stringify(meta) : {}
          meta[SERVER_INFO_META_KEY] = stringify(server_info)
          result[:_meta] = meta
        end

        def normalize_private_listing(result)
          result[:ttlMs] = 0
          result[:cacheScope] = "private"
        end

        def sdk_1_1_gaps?
          SDK_1_1_GAPS.satisfied_by?(Gem::Version.new(::MCP::VERSION))
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
          return unless hash.is_a?(Hash)

          hash.key?(key) ? hash[key] : hash[key.to_s]
        end

        def copy(value)
          case value
          when Hash then value.to_h { |key, child| [ key, copy(child) ] }
          when Array then value.map { |child| copy(child) }
          when String then value.dup
          else value
          end
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
          case value
          when Hash
            value.each { |key, child| deep_freeze(key); deep_freeze(child) }
          when Array
            value.each { |child| deep_freeze(child) }
          end
          value.freeze
        end
      end

      private_constant :ResponseNormalizer
    end
  end
end
