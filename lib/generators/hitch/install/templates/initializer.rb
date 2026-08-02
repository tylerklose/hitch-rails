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
  # from it — Client ID Metadata Documents, which MCP 2026-07-28 makes a
  # SHOULD for authorization servers, having deprecated Dynamic Client
  # Registration. Clients read `client_id_metadata_document_supported`
  # from your discovery document to decide which to use, so leaving this
  # off keeps clients from selecting CIMD. DCR is controlled separately below.
  #
  # This needs your app to reach arbitrary https hosts on port 443
  # DIRECTLY. Hitch deliberately ignores http_proxy — honouring it would
  # reach the destination from the proxy's egress rather than your app's,
  # which is part of what keeps this from being an SSRF hole. If your
  # only outbound path is a proxy, or this tier has no outbound internet,
  # set this to false; otherwise the server advertises support it cannot
  # deliver, and conformant clients will stop falling back to DCR.
  #
  #   bin/rails 'hitch:cimd:check[https://some-client.example/client.json]'
  #
  # exercises the real fetch path against a document you trust, to
  # confirm egress before you rely on it.
  config.client_id_metadata_enabled = true

  # Dynamic Client Registration is unauthenticated and deprecated by the MCP
  # specification, so new installations do not expose it. If you enable it in
  # production, also configure a fleet-shared store whose
  # increment_with_expiry(key:, expires_in:) atomically increments and sets the
  # first-write expiry, returns the post-increment Integer, and whose shared?
  # method returns true. Missing or failed stores make registration unavailable.
  config.dynamic_client_registration_enabled = false
  config.dynamic_client_registration_limit = { to: 20, within: 1.minute }
  # config.dynamic_client_registration_rate_store = MyDcrRateStore.new

  # Bounds on outbound metadata fetches. Both are per process, so a fleet
  # ceiling is the value times your worker count.
  # config.client_id_metadata_max_concurrent_fetches = 4   # nil disables; 0 blocks
  # config.client_id_metadata_fetches_per_minute = 20      # per signed-in principal

  # Token lifetimes. Defaults: 1 hour access tokens, 10 minute auth codes.
  # config.access_token_lifetime_seconds = 3600
  # config.authorization_code_lifetime_seconds = 600
end
