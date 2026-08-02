# frozen_string_literal: true

require "uri"

module Hitch
  module MCP
    class Configuration
      DEFAULT_MAX_REQUEST_BYTES = 1_048_576
      DEFAULT_MAX_RESULT_BYTES = 1_048_576
      MAX_REDIS_URL_BYTES = 2_048

      attr_reader :registry, :server_info, :scope_resolver, :request_limit,
        :rate_limit_redis_url, :max_request_bytes, :max_result_bytes

      def initialize
        @registry = nil
        @registry_snapshot = nil
        @registry_mutex = Mutex.new
        @server_info = nil
        @scope_resolver = nil
        @request_limit = nil
        @rate_limit_redis_url = nil
        @rate_store = nil
        @rate_store_identity = nil
        @rate_store_mutex = Mutex.new
        @max_request_bytes = DEFAULT_MAX_REQUEST_BYTES
        @max_result_bytes = DEFAULT_MAX_RESULT_BYTES
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

      def scope_resolver=(value)
        unless value.nil? || value.respond_to?(:call)
          raise ArgumentError, "mcp.scope_resolver must be callable"
        end

        @scope_resolver = value
      end

      def request_limit=(value)
        @request_limit = normalize_request_limit(value)
      end

      def rate_limit_redis_url=(value)
        normalized = normalize_redis_url(value)
        stale_store = @rate_store_mutex.synchronize do
          stale = @rate_store
          @rate_limit_redis_url = normalized
          @rate_store = nil
          @rate_store_identity = nil
          stale
        end
        close_rate_store(stale_store)
        @rate_limit_redis_url
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
        return true unless runtime_configured?

        unless registry.is_a?(String) && !registry.empty?
          raise ArgumentError,
            "mcp.registry is required when the Hitch::MCP endpoint runtime is configured"
        end
        unless server_info.respond_to?(:call)
          raise ArgumentError,
            "mcp.server_info is required when the Hitch::MCP endpoint runtime is configured"
        end
        unless scope_resolver.respond_to?(:call)
          raise ArgumentError,
            "mcp.scope_resolver is required when the Hitch::MCP endpoint runtime is configured"
        end
        unless request_limit
          raise ArgumentError,
            "mcp.request_limit is required when the Hitch::MCP endpoint runtime is configured"
        end

        normalize_request_limit(request_limit)
        normalize_redis_url(rate_limit_redis_url)
        if production? && rate_limit_redis_url.nil?
          raise ArgumentError,
            "mcp.rate_limit_redis_url is required in production when the Hitch::MCP endpoint runtime is configured"
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

      def prepare_rate_store!
        validate!
        identity = [ rate_limit_redis_url, production? ].freeze
        stale_store = nil

        @rate_store_mutex.synchronize do
          return @rate_store if @rate_store && @rate_store_identity == identity

          replacement = if rate_limit_redis_url
            RedisRateStore.new(url: rate_limit_redis_url)
          else
            MemoryRateStore.new
          end
          stale_store = @rate_store
          @rate_store = replacement
          @rate_store_identity = identity
        end

        close_rate_store(stale_store)
        @rate_store
      end

      def rate_store!
        @rate_store_mutex.synchronize do
          @rate_store || raise(ArgumentError, "MCP request rate store is unavailable")
        end
      end

      def shutdown_rate_store!
        stale_store = @rate_store_mutex.synchronize do
          stale = @rate_store
          @rate_store = nil
          @rate_store_identity = nil
          stale
        end
        close_rate_store(stale_store)
      end

      def runtime_configured?
        !registry.nil? || !server_info.nil? || !scope_resolver.nil? ||
          !request_limit.nil? || !rate_limit_redis_url.nil?
      end

      def normalize_request_limit(value)
        unless value.respond_to?(:to_h)
          raise ArgumentError, "mcp.request_limit must contain :to and :within"
        end

        mapping = value.to_h
        unless mapping.is_a?(Hash)
          raise ArgumentError, "mcp.request_limit must contain :to and :within"
        end

        normalized = {}
        mapping.each do |key, setting|
          name = case key
          when :to, "to" then :to
          when :within, "within" then :within
          end
          unless name && !normalized.key?(name)
            raise ArgumentError, "mcp.request_limit must contain only :to and :within"
          end

          normalized[name] = setting
        end
        unless normalized.keys.sort == %i[to within].sort
          raise ArgumentError, "mcp.request_limit must contain only :to and :within"
        end

        to = positive_integer(normalized.fetch(:to), "mcp.request_limit[:to]")
        within = positive_duration_seconds(normalized.fetch(:within))
        { to:, within: }.freeze
      rescue NoMethodError, TypeError
        raise ArgumentError, "mcp.request_limit must contain only :to and :within"
      end

      def positive_integer(value, name)
        unless value.is_a?(Integer) && value.positive?
          raise ArgumentError, "#{name} must be a positive Integer"
        end

        value
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

      def normalize_redis_url(value)
        return if value.nil?

        unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
            value.bytesize <= MAX_REDIS_URL_BYTES && !value.match?(/[\x00-\x20\x7F]/)
          raise ArgumentError, "mcp.rate_limit_redis_url must be a valid redis:// or rediss:// URL"
        end

        uri = URI.parse(value)
        path = uri.path.to_s
        valid_path = path.empty? || path == "/" || path.match?(/\A\/[0-9]+\z/)
        unless %w[redis rediss].include?(uri.scheme&.downcase) && uri.host &&
            !uri.host.empty? && uri.fragment.nil? && valid_path
          raise ArgumentError, "mcp.rate_limit_redis_url must be a valid redis:// or rediss:// URL"
        end

        value.dup.freeze
      rescue URI::InvalidURIError
        raise ArgumentError, "mcp.rate_limit_redis_url must be a valid redis:// or rediss:// URL"
      end

      def production?
        defined?(Rails) && Rails.env.production?
      end

      def close_rate_store(store)
        store&.close
      rescue StandardError
        nil
      end
    end
  end
end
