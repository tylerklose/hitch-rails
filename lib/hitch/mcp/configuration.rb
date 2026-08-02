# frozen_string_literal: true

module Hitch
  module MCP
    class Configuration
      DEFAULT_MAX_REQUEST_BYTES = 1_048_576

      attr_reader :registry, :server_info, :max_request_bytes

      def initialize
        @registry = nil
        @registry_snapshot = nil
        @registry_mutex = Mutex.new
        @server_info = nil
        @max_request_bytes = DEFAULT_MAX_REQUEST_BYTES
      end

      def registry=(value)
        unless value.is_a?(String) && !value.empty?
          raise ArgumentError, "mcp.registry must be a nonempty String constant name"
        end

        @registry_mutex.synchronize do
          @registry = value.dup.freeze
          @registry_snapshot = nil
        end
        @registry
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
        return true if registry.nil? && server_info.nil?

        unless registry.is_a?(String) && !registry.empty?
          raise ArgumentError,
            "mcp.registry is required when the Hitch::MCP endpoint runtime is configured"
        end

        true
      end

      private

      def prepare_registry!(supported_scopes:)
        @registry_mutex.synchronize do
          @registry_snapshot = nil
          @registry_snapshot = Hitch::MCP::Registry.__send__(
            :build_snapshot,
            registry_name: @registry,
            supported_scopes:
          )
        end
      end

      def registry_snapshot!
        @registry_mutex.synchronize do
          @registry_snapshot || raise(ArgumentError, "MCP registry is unavailable")
        end
      end
    end
  end
end
