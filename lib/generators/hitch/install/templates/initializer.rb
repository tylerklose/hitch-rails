# frozen_string_literal: true

# hitch-rails configuration. See github.com/tylerklose/hitch-rails for
# the full reference. Edit values then run `bin/rails db:migrate`.
Hitch.configure do |config|
  # Which AR model is the OAuth principal (the user/account/client being
  # identified by the token). Default "User". Override if your host app
  # has a different identity model (e.g. "Account", "MCPClient").
  config.principal_model = "User"

  # This MCP server's canonical resource URI for RFC 8707 audience
  # binding. MUST match what MCP clients send when requesting tokens
  # via the `resource` parameter. Required for spec conformance.
  config.resource_uri = "https://your-app.example.com/mcp"

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
  # off keeps every client on the deprecated path. DCR keeps working
  # either way.
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

  # Bounds on outbound metadata fetches. Both are per process, so a fleet
  # ceiling is the value times your worker count.
  # config.client_id_metadata_max_concurrent_fetches = 4   # nil disables; 0 blocks
  # config.client_id_metadata_fetches_per_minute = 20      # per signed-in principal

  # Token lifetimes. Defaults: 1 hour access tokens, 10 minute auth codes.
  # config.access_token_lifetime_seconds = 3600
  # config.authorization_code_lifetime_seconds = 600
end
