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

      # The boot-time counterpart to resolve, for the two checks that run while
      # the application is still initializing.
      #
      # resolve asks ActionController::Base for the default store, and touching
      # that class during initialization is a premature load: Rails 8.2 logs a
      # warning with a full backtrace on every boot, and Rails has been
      # promoting that class of warning to errors.
      #
      # Deferring with on_load(:action_controller_base) is worse than the
      # warning and was shipped once. That hook fires from run_load_hooks at
      # the end of the class body, while cache_store is assigned later still,
      # from inside the on_load(:action_controller) block that
      # action_controller.set_configs registers. The store came back nil and
      # killed the boot — in the fall-back case the deferral existed for.
      #
      # config.action_controller.cache_store is the same value
      # ActionController::Base.cache_store reads, and reading configuration
      # loads no controller and defers nothing, so an unshared store still
      # fails the boot. The trailing Rails.cache mirrors what set_configs
      # itself defaults to, so this does not depend on having run after it.
      def assert_shared_at_boot!(configured, setting:)
        store = configured ||
          Rails.application.config.action_controller.cache_store ||
          Rails.cache
        assert_shared!(store, setting: setting)
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
