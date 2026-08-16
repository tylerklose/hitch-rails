# frozen_string_literal: true

# hitch-rails configuration. See github.com/tylerklose/hitch-rails for
# the full reference. Edit values then run `bin/rails db:migrate`.
Hitch.configure do |config|
  # This MCP server's canonical resource URI for RFC 8707 audience
  # binding. MUST match what MCP clients send when requesting tokens
  # via the `resource` parameter. Required for spec conformance.
  config.resource_uri = "https://your-app.example.com/mcp"

  # The resource URI host is accepted automatically. Add only exact public
  # proxy hosts that may legitimately reach Hitch's engine routes.
  config.allowed_hosts = []

  # Browser origins are denied by default. Add exact origins, including scheme
  # and non-default port. Development/test also accept loopback origins.
  config.allowed_origins = []

  # Display name shown on the consent screen.
  config.brand_name = "Your App"

  # Scopes your MCP server supports.
  config.supported_scopes = [ "mcp" ]

  # How the consent screen identifies the signed-in user. Default
  # :current_user (Devise, has_secure_password apps, etc.). Rails 8's
  # built-in `bin/rails g authentication` exposes Current.user instead of
  # a current_user method — Hitch falls back to Current.user
  # automatically, so no change is needed there. Override only if your
  # app uses a differently-named method (e.g. :current_account).
  # config.principal_method = :current_user

  # Accept an https URL as a client_id and fetch the client's metadata
  # from it — Client ID Metadata Documents, the registration mechanism
  # MCP 2026-07-28 prefers over DCR. Requires DIRECT outbound https on
  # port 443 (Hitch deliberately ignores http_proxy); if this tier has no
  # direct egress, set false so discovery does not advertise support it
  # cannot deliver. Background in the README's CIMD section. Verify with:
  #
  #   bin/rails 'hitch:cimd:check[https://some-client.example/client.json]'
  config.client_id_metadata_enabled = true

  # Dynamic Client Registration is unauthenticated and deprecated by the MCP
  # specification, so new installations do not expose it. Its rate limit counts
  # through config.cache_store; set the store below only to keep registration
  # attempts out of the application's general cache.
  config.dynamic_client_registration_enabled = false
  config.dynamic_client_registration_limit = { to: 20, within: 1.minute }
  # config.dynamic_client_registration_rate_store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV["REDIS_URL"])

  # Bounds on outbound metadata fetches. Both are per process, so a fleet
  # ceiling is the value times your worker count.
  # config.client_id_metadata_max_concurrent_fetches = 4   # nil disables; 0 blocks
  # config.client_id_metadata_fetches_per_minute = 20      # per signed-in principal

  # Token lifetimes. Defaults: 1 hour access tokens, 10 minute auth codes.
  # config.access_token_lifetime_seconds = 3600
  # config.authorization_code_lifetime_seconds = 600
end
