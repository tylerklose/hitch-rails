# frozen_string_literal: true

module Hitch
  module MCP
    class RequestRateLimiter
      class << self
        def call(principal:, client_id:, configuration: Hitch.configuration.mcp)
          limit = configuration.request_limit
          raise ArgumentError, "MCP request limit is unavailable" unless limit

          key = RateLimitKey.call(principal:, client_id:)
          count, ttl_ms = configuration.__send__(:rate_store!).increment(
            key:,
            window_ms: limit.fetch(:within) * 1_000
          )
          unless count.instance_of?(Integer) && count.positive? &&
              ttl_ms.instance_of?(Integer) && ttl_ms.positive?
            raise ArgumentError, "MCP request rate store returned an invalid response"
          end

          return :allow if count <= limit.fetch(:to)

          retry_after = [ limit.fetch(:within), (ttl_ms / 1_000.0).ceil ].max
          { retry_after: }.freeze
        end
      end
    end
    private_constant :RequestRateLimiter
  end
end
