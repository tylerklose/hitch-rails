# frozen_string_literal: true

module Hitch
  module MCP
    # Opt-in wrapper that labels attacker-influenced text inside a tool result.
    # Hitch never wraps automatically; the tool author chooses what to label.
    class UntrustedText
      OPENING_PREFIX = '<untrusted source="'
      OPENING_SUFFIX = '">'
      CLOSING = "</untrusted>"
      # A space after `<` keeps the bytes visible without matching CLOSING.
      NEUTRALIZED_CLOSING = "< /untrusted>"
      STRIP = /[\u{061C}\u{200B}-\u{200D}\u{202A}-\u{202E}\u{2066}-\u{2069}\u{FEFF}]+/
      private_constant :OPENING_PREFIX, :OPENING_SUFFIX, :CLOSING, :NEUTRALIZED_CLOSING, :STRIP

      class << self
        def wrap(text, source:)
          raise ArgumentError, "text must be a String" unless text.is_a?(String)
          unless source.is_a?(String) && source.present?
            raise ArgumentError, "source must be a nonempty String"
          end

          labeled_source = sanitize(source).tr('"', "'")
          "#{OPENING_PREFIX}#{labeled_source}#{OPENING_SUFFIX}#{sanitize(text)}#{CLOSING}".freeze
        end

        private

        def sanitize(value)
          value.gsub(STRIP, "").gsub(CLOSING, NEUTRALIZED_CLOSING)
        end
      end
    end
  end
end
