# frozen_string_literal: true

require "ipaddr"
require "openssl"

module Hitch
  # Private fixed-window guard for unauthenticated client registration. It
  # counts through the host application's own cache store; see
  # Hitch::RateLimitStore.
  class DynamicRegistrationRateLimit
    class Unavailable < StandardError; end

    class Exceeded < StandardError
      attr_reader :retry_after

      def initialize(retry_after)
        @retry_after = retry_after
        super("dynamic client registration rate limit exceeded")
      end
    end

    SETTING = "config.dynamic_client_registration_rate_store"

    class << self
      def check!(remote_ip:)
        configuration = Hitch.configuration
        limit = configuration.dynamic_client_registration_limit
        count = increment(
          configuration.dynamic_client_registration_rate_store,
          key_for(remote_ip),
          limit.fetch(:within)
        )
        # A store that cannot count returns nil, the way Rails' :null_store
        # does. Unlike MCP request admission, which sits behind a bearer token,
        # registration is unauthenticated: an uncountable store in production
        # would let anyone create unlimited clients, so refuse rather than
        # admit. Production also refuses such stores at boot; this is the
        # second lock on an unauthenticated write.
        if count.nil?
          raise Unavailable, "#{SETTING} cannot count registration attempts" if Rails.env.production?

          return true
        end
        raise Exceeded, limit.fetch(:within) if count > limit.fetch(:to)

        true
      end

      private

      def increment(store, key, expires_in)
        count = store.increment(key, 1, expires_in: expires_in)
        return if count.nil?
        raise Unavailable, "DCR rate store returned an invalid count" unless count.is_a?(Integer)

        count
      rescue Unavailable
        raise
      # NotImplementedError (a ScriptError): raised by the base
      # ActiveSupport::Cache::Store#increment when a store never overrode it.
      rescue NotImplementedError, StandardError
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
    end
  end
end
