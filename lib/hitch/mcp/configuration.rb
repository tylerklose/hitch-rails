# frozen_string_literal: true

module Hitch
  module MCP
    class Configuration
      DEFAULT_MAX_REQUEST_BYTES = 1_048_576

      attr_reader :server_info, :max_request_bytes

      def initialize
        @server_info = nil
        @max_request_bytes = DEFAULT_MAX_REQUEST_BYTES
      end

      def server_info=(value)
        unless value.nil? || value.respond_to?(:call)
          raise ArgumentError, "mcp.server_info must be callable"
        end

        @server_info = value
      end

      def max_request_bytes=(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "mcp.max_request_bytes must be a positive integer"
        end

        @max_request_bytes = value
      end

      def validate!
        true
      end
    end
  end
end
