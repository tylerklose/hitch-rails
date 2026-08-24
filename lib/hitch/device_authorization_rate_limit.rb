# frozen_string_literal: true

module Hitch
  # The device flow's two fixed-window quotas, counted through the host
  # application's cache store. Neither is politeness: minting is an
  # unauthenticated database write, and the verification quota is a term in
  # the user code's brute-force math (RFC 8628 §5.1) — the fail-closed
  # policy both apply lives in Hitch::RateLimitStore.
  class DeviceAuthorizationRateLimit
    SETTING = "config.device_authorization_rate_store"

    class << self
      # Per IP: anyone may ask for a code, so the mint quota is keyed the
      # way registration's is.
      def check_mint!(remote_ip:)
        check!("hitch:device:ip:", RateLimitStore.normalize_ip(remote_ip),
          Hitch.configuration.device_authorization_limit)
      end

      # Per signed-in principal, checked only after authentication:
      # anonymous traffic cannot drain a person's guessing budget.
      def check_verification!(principal:)
        actor = RateLimitStore.actor_for(principal)
        # A principal that cannot be identified cannot be counted, and
        # counting is what makes short codes safe — refuse, don't admit
        # unmetered.
        raise RateLimitStore::Unavailable, "principal has no id to rate limit" if actor.nil?

        check!("hitch:device:code:", actor,
          Hitch.configuration.device_code_verification_limit)
      end

      private

      def check!(prefix, identity, limit)
        RateLimitStore.check!(
          Hitch.configuration.device_authorization_rate_store,
          RateLimitStore.hmac_key(prefix, identity),
          limit,
          setting: SETTING
        )
      end
    end
  end
end
