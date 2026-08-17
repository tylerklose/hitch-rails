# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Strict media negotiation for the endpoint (RFC 7231 §5.3): the request
      # body must be exactly application/json, and Accept must admit both
      # response framings the protocol may use.
      module MediaType
        ACCEPT_TYPES = %w[application/json text/event-stream].freeze
        MEDIA_TYPE_PATTERN = %r{\A[A-Za-z0-9!#$%&'*+.^_`|~-]+/[A-Za-z0-9!#$%&'*+.^_`|~-]+\z}
        PARAMETER_PATTERN = /\A[A-Za-z0-9!#$%&'*+.^_`|~-]+=[^;\s]+\z/
        QUALITY_PATTERN = /\A(?:0(?:\.\d{0,3})?|1(?:\.0{0,3})?)\z/

        module_function

        def json_content_type?(value)
          return false unless value.is_a?(String) && value.valid_encoding?
          return false if value.empty? || value.include?(",") || HeaderField::CONTROLS.match?(value)

          media_type, *parameters = value.split(";", -1).map { |part| HeaderField.trim_ows(part) }
          return false unless media_type&.downcase == "application/json"

          parameters.all? { |parameter| parameter&.match?(PARAMETER_PATTERN) }
        end

        def accepts_required_types?(value)
          return false unless value.is_a?(String) && value.valid_encoding?
          return false if value.empty? || HeaderField::CONTROLS.match?(value)

          accepted = {}
          value.split(",", -1).each do |entry|
            media_type, quality = accept_entry(entry)
            return false unless media_type

            accepted[media_type] = true if ACCEPT_TYPES.include?(media_type) && quality.positive?
          end
          ACCEPT_TYPES.all? { |media_type| accepted[media_type] }
        end

        def accept_entry(entry)
          media_type, *parameters = entry.split(";", -1).map { |part| HeaderField.trim_ows(part) }
          return [ nil, nil ] unless media_type&.match?(MEDIA_TYPE_PATTERN)

          quality = 1.0
          quality_seen = false
          parameters.each do |parameter|
            name, raw_value = parameter.to_s.split("=", 2)
            return [ nil, nil ] unless name && raw_value
            next unless name.casecmp?("q")
            return [ nil, nil ] if quality_seen || !raw_value.match?(QUALITY_PATTERN)

            quality_seen = true
            quality = raw_value.to_f
          end
          [ media_type.downcase, quality ]
        end
      end
    end
  end
end
