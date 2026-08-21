# frozen_string_literal: true

require "json"
require "openssl"

module Hitch
  module MCP
    module Internal
      # HMAC-SHA256 digest over canonical JSON identity components, shared by
      # rate-limit keying and observation identity. Each caller keeps its own
      # salt, component layout, and output shape.
      class HmacIdentity
        MAX_COMPONENT_BYTES = 2_048

        class << self
          def digest(salt:, components:, key_generator:, unavailable_message:)
            secret = key_generator.generate_key(salt, 32)
            unless secret.is_a?(String) && secret.bytesize == 32
              raise ArgumentError, unavailable_message
            end

            OpenSSL::HMAC.hexdigest("SHA256", secret, JSON.generate(components)).freeze
          end

          def component(value, invalid_message:)
            unless value.is_a?(String) && value.valid_encoding? && !value.empty? &&
                value.bytesize <= MAX_COMPONENT_BYTES
              raise ArgumentError, invalid_message
            end

            value
          end
        end
      end
    end
  end
end
