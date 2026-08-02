# frozen_string_literal: true

module Hitch
  module MCP
    class MemoryRateStore
      Entry = Data.define(:count, :expires_at)
      private_constant :Entry

      def initialize(clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @clock = clock
        @entries = {}
        @mutex = Mutex.new
      end

      def increment(key:, window_ms:)
        unless key.is_a?(String) && !key.empty? && window_ms.is_a?(Integer) && window_ms.positive?
          raise ArgumentError, "MCP request rate store input is invalid"
        end

        @mutex.synchronize do
          now = @clock.call
          entry = @entries[key]
          entry = nil if entry && entry.expires_at <= now
          entry = if entry
            Entry.new(count: entry.count + 1, expires_at: entry.expires_at)
          else
            Entry.new(count: 1, expires_at: now + (window_ms / 1_000.0))
          end
          @entries[key] = entry
          ttl_ms = ((entry.expires_at - now) * 1_000).ceil
          raise ArgumentError, "MCP request rate store clock is invalid" unless ttl_ms.positive?

          [ entry.count, ttl_ms ].freeze
        end
      end

      def close
        @mutex.synchronize { @entries.clear }
        nil
      end
    end
    private_constant :MemoryRateStore
  end
end
