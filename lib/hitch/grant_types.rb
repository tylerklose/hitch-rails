# frozen_string_literal: true

module Hitch
  # Which OAuth grants the token endpoint will actually accept right now.
  #
  # One source of truth on purpose. Discovery metadata advertising a grant is
  # a promise a conformant client will act on, so a hardcoded
  # `grant_types_supported` that drifted from the endpoint's real behaviour
  # would send clients to a door this server answers with
  # unsupported_grant_type.
  module GrantTypes
    DEVICE_CODE = "urn:ietf:params:oauth:grant-type:device_code"

    module_function

    def supported
      types = [ "authorization_code" ]
      types << "refresh_token" if Hitch.configuration.refresh_tokens_enabled
      types << DEVICE_CODE if Hitch.configuration.device_authorization_enabled
      types.freeze
    end
  end
end
