# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # CORS decisions for the endpoint: an exact origin allowlist (plus
      # loopback in development and test), and a fixed preflight contract —
      # POST only, a closed request-header set.
      module CorsPolicy
        ALLOWED_REQUEST_HEADERS = %w[
          Content-Type
          Authorization
          MCP-Protocol-Version
          Mcp-Method
          Mcp-Name
        ].freeze
        LOOPBACK_ORIGIN = %r{\Ahttps?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z}
        PREFLIGHT_RESPONSE_HEADERS = {
          "Access-Control-Allow-Methods" => "POST",
          "Access-Control-Allow-Headers" => ALLOWED_REQUEST_HEADERS.join(", "),
          "Access-Control-Max-Age" => "600"
        }.freeze

        module_function

        def origin_allowed?(origin)
          return false unless origin.is_a?(String) && origin.valid_encoding?
          return false if origin.empty? || origin.include?(",") || HeaderField::CONTROLS.match?(origin)
          return true if Hitch.configuration.allowed_origins.include?(origin)

          Rails.env.local? && LOOPBACK_ORIGIN.match?(origin)
        end

        def preflight_allowed?(requested_method:, requested_headers:)
          method = HeaderField.single(requested_method)
          headers = requested_header_list(requested_headers)
          return false unless method == "POST" && headers

          allowed = ALLOWED_REQUEST_HEADERS.map(&:downcase)
          headers.all? { |header| allowed.include?(header.downcase) }
        end

        def requested_header_list(value)
          return [] if value.nil? || value.empty?
          return unless value.is_a?(String) && value.valid_encoding? && !HeaderField::CONTROLS.match?(value)

          values = value.split(",", -1).map { |entry| HeaderField.trim_ows(entry) }
          values unless values.any? { |entry| entry.nil? || entry.empty? }
        end
      end
    end
  end
end
