# frozen_string_literal: true

require "uri"

Hitch.configure do |config|
  config.resource_uri = ENV.fetch("HITCH_CONFORMANCE_RESOURCE_URI", "https://dummy.test/mcp")
  resource_host = URI.parse(config.resource_uri).hostname
  config.allowed_hosts = [ "www.example.com", resource_host ].compact.uniq
  config.allowed_origins = [ "https://claude.ai" ]
  config.dynamic_client_registration_enabled = true
  config.client_id_metadata_enabled = ENV["HITCH_CONFORMANCE"] == "1"
  config.brand_name = "Dummy"
  config.mcp.registry = "McpToolRegistry"
  config.mcp.server_info = ->(_context) {
    {
      name: "hitch-dummy",
      version: "0.2.0",
      title: "Hitch Dummy",
      instructions: "Use only tools available to the signed-in principal."
    }
  }
  config.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
  config.mcp.max_request_bytes = 1_024
end
