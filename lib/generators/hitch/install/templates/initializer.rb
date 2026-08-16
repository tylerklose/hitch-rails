# frozen_string_literal: true

# hitch-rails configuration. These are the knobs every host must set; the
# full reference (proxy hosts, scopes, token lifetimes, byte caps, rate
# limits) lives at github.com/tylerklose/hitch-rails.
Hitch.configure do |config|
  # This MCP server's canonical resource URI for RFC 8707 audience binding.
  # MUST match what MCP clients send in the `resource` parameter.
  config.resource_uri = "https://your-app.example.com/mcp"

  # Display name shown on the OAuth consent screen.
  config.brand_name = "Your App"

  # Exact browser origins allowed to call the endpoint, including scheme and
  # non-default port. Denied by default; development and test also accept
  # loopback origins.
  config.allowed_origins = []

  # Client ID Metadata Documents — how MCP 2026-07-28 clients register.
  # Requires DIRECT outbound https on port 443 (Hitch deliberately ignores
  # http_proxy); set false if this tier has no direct egress. Verify with:
  #   bin/rails 'hitch:cimd:check[https://some-client.example/client.json]'
  config.client_id_metadata_enabled = true

  # Dynamic Client Registration is unauthenticated and deprecated by the MCP
  # specification, so new installations do not expose it.
  config.dynamic_client_registration_enabled = false

  # The authenticated /mcp endpoint. Tools stay deny-default until they are
  # reviewed and registered in app/tools/mcp_tool_registry.rb.
  config.mcp.enabled = true
  config.mcp.registry = "McpToolRegistry"
end
