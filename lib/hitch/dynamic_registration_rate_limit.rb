# frozen_string_literal: true

require "digest"
require "ipaddr"
require "openssl"

module Hitch
  # Private fixed-window guard for unauthenticated client registration.
  class DynamicRegistrationRateLimit
    class Unavailable < StandardError; end

    class Exceeded < StandardError
      attr_reader :retry_after

      def initialize(retry_after)
        @retry_after = retry_after
        super("dynamic client registration rate limit exceeded")
      end
    end

    class MemoryStore
      def initialize
        @entries = {}
        @mutex = Mutex.new
      end

      def shared?
        false
      end

      def increment_with_expiry(key:, expires_in:)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)

        @mutex.synchronize do
          @entries.delete_if { |_entry_key, entry| entry.fetch(:expires_at) <= now }
          entry = @entries[key]

          if entry
            entry[:count] += 1
          else
            entry = { count: 1, expires_at: now + expires_in }
            @entries[key] = entry
          end

          entry.fetch(:count)
        end
      end
    end
    private_constant :MemoryStore

    class << self
      def check!(remote_ip:, configuration: Hitch.configuration, production: Rails.env.production?)
        limit = configuration.dynamic_client_registration_limit
        store = resolve_store(configuration, production: production)
        count = increment(store, key_for(remote_ip), limit.fetch(:within))

        raise Exceeded, limit.fetch(:within) if count > limit.fetch(:to)

        true
      end

      def validate_production_store!(store)
        unless store&.respond_to?(:increment_with_expiry) && store.respond_to?(:shared?)
          raise Unavailable,
            "production DCR requires a shared store implementing increment_with_expiry(key:, expires_in:) and shared?"
        end
        unless store.shared? == true
          raise Unavailable, "production DCR rate store must report shared? == true"
        end

        true
      rescue Unavailable
        raise
      rescue StandardError
        raise Unavailable, "production DCR rate store capability check failed"
      end

      def reset_nonproduction_store!
        @nonproduction_store = MemoryStore.new
      end

      private

      def resolve_store(configuration, production:)
        store = configuration.dynamic_client_registration_rate_store
        return nonproduction_store if store.nil? && !production

        validate_production_store!(store)
        store
      end

      def increment(store, key, expires_in)
        count = store.increment_with_expiry(key: key, expires_in: expires_in)
        unless count.is_a?(Integer) && count.positive?
          raise Unavailable, "DCR rate store returned an invalid count"
        end

        count
      rescue Unavailable
        raise
      rescue StandardError
        raise Unavailable, "DCR rate store increment failed"
      end

      def key_for(remote_ip)
        normalized_ip = IPAddr.new(remote_ip.to_s).to_s
        secret = Rails.application.secret_key_base.to_s
        digest = OpenSSL::HMAC.hexdigest("SHA256", secret, normalized_ip)
        "hitch:dcr:ip:#{digest}"
      rescue IPAddr::InvalidAddressError
        raise Unavailable, "DCR request IP could not be normalized"
      end

      def nonproduction_store
        @nonproduction_store ||= MemoryStore.new
      end
    end
  end
end
