# frozen_string_literal: true

module Hitch
  # Exact-origin CORS support for Hitch endpoints and host controllers that
  # opt in. Preflight is validated separately from ordinary response headers.
  module CorsSupport
    extend ActiveSupport::Concern

    included do
      before_action :handle_hitch_preflight, if: -> { request.options? }
      before_action :set_cors_headers, unless: -> { request.options? }
    end

    private

    ALLOWED_REQUEST_HEADERS = [
      "Content-Type",
      "Authorization",
      "MCP-Protocol-Version",
      "Mcp-Method",
      "Mcp-Name"
    ].freeze

    LOOPBACK_PATTERN = %r{\Ahttps?://(?:localhost|127\.0\.0\.1|\[::1\])(?::\d+)?\z}.freeze

    def set_cors_headers
      append_vary_header("Origin")
      origin = request.headers["Origin"]
      return unless allowed_origin?(origin)

      response.headers["Access-Control-Allow-Origin"] = origin
    end

    def allowed_origin?(origin)
      return false unless origin.is_a?(String)
      return true if Hitch.configuration.allowed_origins.include?(origin)

      loopback_origins_allowed? && LOOPBACK_PATTERN.match?(origin)
    end

    # Called by Hitch::PreflightsController. Host-owned endpoints may call the
    # same private helper from an explicit action, keeping route ownership clear.
    def hitch_preflight(allowed_methods:)
      append_vary_header("Origin")
      append_vary_header("Access-Control-Request-Method")
      append_vary_header("Access-Control-Request-Headers")

      origin = request.headers["Origin"]
      requested_method = request.headers["Access-Control-Request-Method"].to_s.upcase
      methods = Array(allowed_methods).map { |method| method.to_s.upcase }.uniq
      requested_headers = parsed_requested_headers

      unless allowed_origin?(origin) && methods.include?(requested_method) && requested_headers_allowed?(requested_headers)
        return head :forbidden
      end

      response.headers["Access-Control-Allow-Origin"] = origin
      response.headers["Access-Control-Allow-Methods"] = methods.join(", ")
      response.headers["Access-Control-Allow-Headers"] = ALLOWED_REQUEST_HEADERS.join(", ")
      response.headers["Access-Control-Max-Age"] = "600"
      head :no_content
    end

    def handle_hitch_preflight
      methods = request.path_parameters[:target_methods].to_s.split(",").reject(&:empty?)
      methods = [ "POST" ] if methods.empty?
      hitch_preflight(allowed_methods: methods)
    end

    def parsed_requested_headers
      raw = request.headers["Access-Control-Request-Headers"].to_s
      return [] if raw.empty?

      values = raw.split(",", -1).map(&:strip)
      return nil if values.any?(&:empty?)

      values
    end

    def requested_headers_allowed?(headers)
      return false if headers.nil?

      allowed = ALLOWED_REQUEST_HEADERS.map(&:downcase)
      headers.all? { |header| allowed.include?(header.downcase) }
    end

    def loopback_origins_allowed?
      Rails.env.local?
    end

    def append_vary_header(value)
      values = response.headers["Vary"].to_s.split(",").map(&:strip).reject(&:empty?)
      values << value unless values.include?(value)
      response.headers["Vary"] = values.join(", ")
    end
  end
end
