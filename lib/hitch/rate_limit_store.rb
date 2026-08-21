# frozen_string_literal: true

module Hitch
  # Both Hitch rate limits — unauthenticated client registration and
  # authenticated MCP requests — count through the host application's own
  # ActiveSupport::Cache store, the way ActionController::RateLimiting does.
  # Neither adds a service to the deployment, and neither asks the host to
  # implement an interface.
  module RateLimitStore
    class << self
      def resolve(configured)
        configured || ActionController::Base.cache_store
      end

      def validate!(store, setting:)
        return store if store.nil? || store.respond_to?(:increment)

        raise ArgumentError,
          "#{setting} must be an ActiveSupport::Cache store responding to increment"
      end

      # Production boot check, shared by both limiters: the resolved store
      # must be able to count one caller's requests across processes. Unlike
      # validate!, nil is refused here — there is no later to resolve at.
      def assert_shared!(store, setting:)
        unless store.respond_to?(:increment)
          raise ArgumentError,
            "#{setting} must be an ActiveSupport::Cache store responding to increment"
        end
        return true unless unshared?(store)

        raise ArgumentError,
          "#{setting} resolved to #{store.class.name}, which cannot count one caller's " \
            "requests across the processes serving them. Configure a shared " \
            "config.cache_store (Solid Cache, Redis, Memcached) or set #{setting} explicitly."
      end

      # MemoryStore is per process, NullStore retains nothing, and FileStore
      # reads and writes without a lock.
      def unshared?(store)
        store.is_a?(ActiveSupport::Cache::MemoryStore) ||
          store.is_a?(ActiveSupport::Cache::NullStore) ||
          store.is_a?(ActiveSupport::Cache::FileStore)
      end
    end
  end
end
