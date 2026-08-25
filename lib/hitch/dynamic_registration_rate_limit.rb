# frozen_string_literal: true

module Hitch
  # Private fixed-window guard for unauthenticated client registration. It
  # counts through the host application's own cache store; the fail-closed
  # policy lives in Hitch::RateLimitStore.
  class DynamicRegistrationRateLimit
    Unavailable = Hitch::RateLimitStore::Unavailable
    Exceeded = Hitch::RateLimitStore::Exceeded

    SETTING = "config.dynamic_client_registration_rate_store"

    def self.check!(remote_ip:)
      configuration = Hitch.configuration
      RateLimitStore.check!(
        configuration.dynamic_client_registration_rate_store,
        RateLimitStore.hmac_key("hitch:dcr:ip:", RateLimitStore.normalize_ip(remote_ip)),
        configuration.dynamic_client_registration_limit,
        setting: SETTING
      )
    end
  end
end
