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
  config.mcp.enabled = true
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
  config.mcp.request_limit = {
    to: Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_TO", "120"), 10),
    within: Integer(ENV.fetch("HITCH_MCP_REQUEST_LIMIT_WITHIN", "60"), 10).seconds
  }
  # The dummy test environment runs Rails' :null_store default, which cannot
  # count. Admission tests need a real counter, and the cross-process lane
  # needs one shared between processes.
  config.mcp.rate_limit_store = if ENV["HITCH_MCP_REDIS_URL"]
    ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("HITCH_MCP_REDIS_URL"))
  else
    ActiveSupport::Cache::MemoryStore.new
  end
  config.mcp.max_request_bytes = 1_024
  config.mcp.max_result_bytes = 1_024
end
