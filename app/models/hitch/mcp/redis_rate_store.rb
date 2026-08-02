# frozen_string_literal: true

require "redis"

module Hitch
  module MCP
    class RedisRateStore
      LUA = <<~LUA.freeze
        local count = redis.call("INCR", KEYS[1])
        if count == 1 then
          redis.call("PEXPIRE", KEYS[1], ARGV[1])
        end
        local ttl = redis.call("PTTL", KEYS[1])
        return { count, ttl }
      LUA

      def initialize(url:, client: nil)
        @client = client || Redis.new(
          url:,
          timeout: 1.0,
          connect_timeout: 1.0,
          reconnect_attempts: 0
        )
      end

      def increment(key:, window_ms:)
        response = @client.eval(LUA, [ key ], [ window_ms ])
        unless response.is_a?(Array) && response.length == 2 &&
            response.all? { |value| value.is_a?(Integer) }
          raise ArgumentError, "MCP request rate store returned an invalid response"
        end

        count, ttl_ms = response
        unless count.positive? && ttl_ms.positive?
          raise ArgumentError, "MCP request rate store returned an invalid response"
        end

        [ count, ttl_ms ].freeze
      end

      def close
        @client.close
      end
    end
    private_constant :RedisRateStore
  end
end
