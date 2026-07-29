# frozen_string_literal: true

module Hitch
  # CORS support for OAuth endpoints. MCP clients running in a browser
  # context (claude.ai, chatgpt.com, etc.) make cross-origin requests
  # during the OAuth dance and during MCP tool calls.
  module CorsSupport
    extend ActiveSupport::Concern

    included do
      before_action :set_cors_headers
    end

    private

    ALLOWED_ORIGINS = %w[
      https://claude.ai
      https://chatgpt.com
      https://openai.com
      https://gemini.google.com
      https://cursor.com
      https://cursor.sh
      https://windsurf.com
    ].freeze

    LOOPBACK_PATTERN = %r{\Ahttps?://(localhost|127\.0\.0\.1)(:\d+)?\z}.freeze

    def set_cors_headers
      origin = request.headers["Origin"]
      return unless origin
      return unless allowed_origin?(origin)

      response.headers["Access-Control-Allow-Origin"] = origin
      response.headers["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS"
      # MCP 2026-07-28 makes MCP-Protocol-Version, Mcp-Method and
      # Mcp-Name required request headers on Streamable HTTP (the latter
      # two so gateways can route and authorize without parsing the JSON
      # body). A browser-based client sending them fails preflight unless
      # they're allowed here. Widening an allow-list is safe for older
      # clients: one that never sends them is unaffected.
      response.headers["Access-Control-Allow-Headers"] =
        "Content-Type, Authorization, MCP-Protocol-Version, Mcp-Method, Mcp-Name"
      response.headers["Access-Control-Max-Age"] = "86400"
    end

    def allowed_origin?(origin)
      ALLOWED_ORIGINS.include?(origin) || LOOPBACK_PATTERN.match?(origin)
    end
  end
end
