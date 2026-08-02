# frozen_string_literal: true

require "json"
require "openssl"

module Hitch
  module MCP
    class RateLimitKey
      SALT = "hitch/mcp/rate-limit/v1"
      KEY_PREFIX = "hitch:mcp:rate-limit:v1:"
      MAX_COMPONENT_BYTES = 2_048

      class << self
        def call(principal:, client_id:, key_generator: Rails.application.key_generator)
          principal_class = principal.class.respond_to?(:base_class) ? principal.class.base_class : principal.class
          canonical = JSON.generate([
            identity_component(principal_class.name),
            identity_component(principal.id.to_s),
            identity_component(client_id)
          ])
          secret = key_generator.generate_key(SALT, 32)
          unless secret.is_a?(String) && secret.bytesize == 32
            raise ArgumentError, "MCP request rate key is unavailable"
          end

          "#{KEY_PREFIX}#{OpenSSL::HMAC.hexdigest('SHA256', secret, canonical)}".freeze
        end

        private

        def identity_component(value)
          unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
              value.bytesize <= MAX_COMPONENT_BYTES
            raise ArgumentError, "MCP request rate identity is invalid"
          end

          value
        end
      end
    end
    private_constant :RateLimitKey
  end
end
