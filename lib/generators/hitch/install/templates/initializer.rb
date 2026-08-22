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

  # Where to send a signed-out visitor who lands on the consent screen.
  # Without it the browser OAuth flow answers a bare 401 and no MCP client
  # can complete sign-in. "/session/new" is what Rails 8's own
  # `bin/rails generate authentication` creates; Devise uses
  # "/users/sign_in".
  config.login_path = "/session/new"

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

  # A connected client renews itself in the background instead of asking the
  # person again every hour. Nothing here is long-lived: the access token is
  # an hour and is re-minted rather than extended, and the refresh token is
  # replaced on every use. What continues is the grant, and it continues by
  # being used — an unused one expires after 30 days.
  #
  # Uncomment to put a hard cutoff on a grant no matter how actively it is
  # used. Off by default because it disconnects people who have done nothing
  # wrong; set it if you want a stolen refresh token whose real client never
  # returns to expire on a clock rather than waiting for a revocation.
  # config.refresh_token_family_lifetime_seconds = 90 * 86_400
end
