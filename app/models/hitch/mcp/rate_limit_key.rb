# frozen_string_literal: true

module Hitch
  module MCP
    class RateLimitKey
      SALT = "hitch/mcp/rate-limit/v1"
      KEY_PREFIX = "hitch:mcp:rate-limit:v1:"

      class << self
        def call(principal:, client_id:, key_generator: Rails.application.key_generator)
          record_class = principal.class.respond_to?(:base_class) ? principal.class.base_class : principal.class
          invalid_message = "MCP request rate identity is invalid"
          digest = Internal::HmacIdentity.digest(
            salt: SALT,
            components: [
              Internal::HmacIdentity.component(record_class.name, invalid_message:),
              Internal::HmacIdentity.component(principal.id.to_s, invalid_message:),
              Internal::HmacIdentity.component(client_id, invalid_message:)
            ],
            key_generator: key_generator,
            unavailable_message: "MCP request rate key is unavailable"
          )
          "#{KEY_PREFIX}#{digest}".freeze
        end
      end
    end
    private_constant :RateLimitKey
  end
end
