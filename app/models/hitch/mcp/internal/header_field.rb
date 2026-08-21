# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Field-value hygiene shared by the endpoint and the verified request:
      # reject control bytes and comma-combined values, trim optional
      # whitespace (RFC 9110 §5.5-5.6).
      module HeaderField
        CONTROLS = /[\x00-\x08\x0A-\x1F\x7F]/
        OWS = /\A[\x20\x09]*(.*?)[\x20\x09]*\z/m

        module_function

        # The one exact value of a header that must not repeat: nil for
        # missing, invalid, comma-combined, or empty-after-trim values.
        def single(value)
          return unless value.is_a?(String) && value.valid_encoding?
          return if value.include?(",") || CONTROLS.match?(value)

          candidate = trim_ows(value)
          candidate unless candidate.nil? || candidate.empty?
        end

        def trim_ows(value)
          value[OWS, 1]
        end
      end
    end
  end
end
