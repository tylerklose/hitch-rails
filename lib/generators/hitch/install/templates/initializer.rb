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

  # Token lifetimes. Defaults: 1 hour access tokens, 10 minute auth codes.
  # config.access_token_lifetime_seconds = 3600
  # config.authorization_code_lifetime_seconds = 600
end
