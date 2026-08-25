# frozen_string_literal: true

require "ipaddr"
require "openssl"

module Hitch
  # Hitch's rate limits — unauthenticated client registration, the device
  # authorization flow, and authenticated MCP requests — count through the
  # host application's own ActiveSupport::Cache store, the way
  # ActionController::RateLimiting does. Neither adds a service to the
  # deployment, and neither asks the host to implement an interface.
  module RateLimitStore
    class Unavailable < StandardError; end

    class Exceeded < StandardError
      attr_reader :retry_after

      def initialize(retry_after)
        @retry_after = retry_after
        super("rate limit exceeded")
      end
    end

    class << self
      def resolve(configured)
        configured || ActionController::Base.cache_store
      end

      # The fail-closed fixed window every limiter guarding an
      # unauthenticated or guessable surface applies. A store that cannot
      # count returns nil, the way Rails' :null_store does; in production
      # that refuses rather than admits — an uncounted attempt would void
      # the entropy math these limits are a term in — while development and
      # test admit, as Rails does. Production also refuses such stores at
      # boot; this is the second lock.
      def check!(store, key, limit, setting:)
        count = begin
          value = store.increment(key, 1, expires_in: limit.fetch(:within))
          unless value.nil? || value.is_a?(Integer)
            raise Unavailable, "#{setting} returned an invalid count"
          end
          value
        rescue Unavailable
          raise
        # NotImplementedError (a ScriptError): raised by the base
        # ActiveSupport::Cache::Store#increment when a store never overrode it.
        rescue NotImplementedError, StandardError
          raise Unavailable, "#{setting} increment failed"
        end
        if count.nil?
          raise Unavailable, "#{setting} cannot count attempts" if Rails.env.production?

          return true
        end
        raise Exceeded, limit.fetch(:within) if count > limit.fetch(:to)

        true
      end

      # Counting keys carry an HMAC of the identity, never the identity
      # itself: a cache store is not a log, and a shared one is readable by
      # more than this app.
      def hmac_key(prefix, identity)
        secret = Rails.application.secret_key_base.to_s
        "#{prefix}#{OpenSSL::HMAC.hexdigest('SHA256', secret, identity)}"
      end

      def normalize_ip(remote_ip)
        IPAddr.new(remote_ip.to_s).to_s
      rescue IPAddr::InvalidAddressError
        raise Unavailable, "request IP could not be normalized"
      end

      # Class name included so two principal models cannot collide on an
      # integer id; nil when the principal has no id — including a nil
      # one, or every unidentifiable visitor would share one counting
      # bucket — which keeps callers honest about an identity they cannot
      # count.
      def actor_for(principal)
        id = principal.id if principal.respond_to?(:id)
        return nil if id.nil?

        "#{principal.class.name}:#{id}"
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
