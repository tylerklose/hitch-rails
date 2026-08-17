# frozen_string_literal: true

module Hitch
  module MCP
    class Configuration
      DEFAULT_MAX_REQUEST_BYTES = 1_048_576
      DEFAULT_MAX_RESULT_BYTES = 1_048_576
      DEFAULT_REQUEST_LIMIT = { to: 120, within: 60 }.freeze
      DEFAULT_SERVER_INFO = lambda do |_context|
        {
          name: Rails.application.class.module_parent_name.underscore.dasherize,
          version: "1.0.0"
        }
      end
      SETTING = "mcp.rate_limit_store"

      attr_reader :enabled, :registry, :scope_resolver, :request_limit,
        :max_request_bytes, :max_result_bytes

      def initialize
        @enabled = false
        @registry = nil
        @registry_snapshot = nil
        @registry_mutex = Mutex.new
        @server_info = nil
        @scope_resolver = nil
        @request_limit = DEFAULT_REQUEST_LIMIT
        @rate_limit_store = nil
        @max_request_bytes = DEFAULT_MAX_REQUEST_BYTES
        @max_result_bytes = DEFAULT_MAX_RESULT_BYTES
      end

      # The one explicit switch for the authenticated /mcp endpoint runtime.
      def enabled=(value)
        unless value == true || value == false
          raise ArgumentError, "mcp.enabled must be true or false"
        end

        @enabled = value
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

      def server_info
        @server_info || DEFAULT_SERVER_INFO
      end

      def server_info=(value)
        unless value.nil? || value.respond_to?(:call)
          raise ArgumentError, "mcp.server_info must be callable"
        end

        @server_info = value
      end

      def scope_resolver=(value)
        unless value.nil? || value.respond_to?(:call)
          raise ArgumentError, "mcp.scope_resolver must be callable"
        end

        @scope_resolver = value
      end

      def request_limit=(value)
        @request_limit = normalize_request_limit(value)
      end

      # Nil means "whatever this application already configured", which is what
      # ActionController::RateLimiting does. Hosts that want MCP admission kept
      # out of their general cache pass their own ActiveSupport::Cache store.
      def rate_limit_store=(value)
        @rate_limit_store = Hitch::RateLimitStore.validate!(value, setting: SETTING)
      end

      def rate_limit_store
        Hitch::RateLimitStore.resolve(@rate_limit_store)
      end

      def max_request_bytes=(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "mcp.max_request_bytes must be a positive integer"
        end

        @max_request_bytes = value
      end

      def max_result_bytes=(value)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "mcp.max_result_bytes must be a positive integer"
        end

        @max_result_bytes = value
      end

      def validate!
        return true unless enabled

        unless registry.is_a?(String) && !registry.empty?
          raise ArgumentError, "mcp.registry is required when mcp.enabled is true"
        end

        true
      end

      # Resolved separately from validate! because the application's cache store
      # is assembled by Rails' own initializers; this runs from to_prepare, once
      # config.cache_store is settled.
      def validate_rate_limit_store!
        return true unless Rails.env.production?

        Hitch::RateLimitStore.assert_shared!(rate_limit_store, setting: SETTING)
      end

      # Framework lifecycle, not a host knob: the engine's to_prepare hook
      # rebuilds the snapshot; the endpoint reads it per request.
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

      private

      def normalize_request_limit(value)
        unless value.respond_to?(:to_h)
          raise ArgumentError, "mcp.request_limit must contain :to and :within"
        end

        # Duplicate keys across spellings ({ to: 1, "to" => 2 }) produce a
        # third key and fail the comparison.
        mapping = value.to_h
        unless mapping.keys.map(&:to_s).sort == %w[to within]
          raise ArgumentError, "mcp.request_limit must contain only :to and :within"
        end

        to = mapping[:to] || mapping["to"]
        unless to.is_a?(Integer) && to.positive?
          raise ArgumentError, "mcp.request_limit[:to] must be a positive Integer"
        end

        within = positive_duration_seconds(mapping[:within] || mapping["within"])
        { to:, within: }.freeze
      rescue NoMethodError, TypeError
        raise ArgumentError, "mcp.request_limit must contain only :to and :within"
      end

      def positive_duration_seconds(value)
        seconds = if defined?(ActiveSupport::Duration) && value.is_a?(ActiveSupport::Duration)
          float = value.to_f
          value.to_i if float.finite? && float == value.to_i
        elsif value.is_a?(Integer)
          value
        end
        unless seconds&.positive?
          raise ArgumentError,
            "mcp.request_limit[:within] must be a positive whole number of seconds or ActiveSupport::Duration"
        end

        seconds
      end
    end
  end
end
