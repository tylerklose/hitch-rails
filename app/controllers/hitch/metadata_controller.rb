# frozen_string_literal: true

module Hitch
  # OAuth + MCP discovery metadata:
  #   GET /.well-known/oauth-authorization-server (RFC 8414)
  #   GET /.well-known/oauth-protected-resource (RFC 9728)
  class MetadataController < Hitch::PublicEndpointController
    include Hitch::CorsSupport

    def show
      cache_discovery_metadata

      render json: {
        issuer: issuer_url,
        authorization_endpoint: oauth_authorize_url,
        token_endpoint: oauth_token_url,
        revocation_endpoint: oauth_revoke_url,
        registration_endpoint: oauth_register_url,
        response_types_supported: [ "code" ],
        grant_types_supported: [ "authorization_code" ],
        code_challenge_methods_supported: [ "S256" ],
        scopes_supported: Hitch.configuration.supported_scopes,
        # Only "none" — the gem doesn't implement client secret
        # verification at /oauth/token. Advertising
        # client_secret_post would be a lie since the controller
        # never authenticates the secret.
        token_endpoint_auth_methods_supported: [ "none" ]
      }
    end

    def resource
      cache_discovery_metadata

      # RFC 9728 + 2025-11-25 MCP spec: PRM SHOULD include
      # scopes_supported so resource servers can echo per-tool
      # required scopes back in 403 challenges.
      render json: {
        resource: Hitch.configuration.resource_uri.presence || issuer_url,
        authorization_servers: [ issuer_url ],
        bearer_methods_supported: [ "header" ],
        scopes_supported: Hitch.configuration.supported_scopes
      }
    end

    private

    # The metadata body is derived from the request Host (issuer +
    # every endpoint URL come from request.base_url), so it must not be
    # stored in a shared cache that keys on path alone — a forged-Host
    # request could otherwise poison the entry and steer later clients'
    # credential flow to an attacker-controlled token_endpoint
    # (RFC 9700 mix-up). Cache privately (per client), never `public`,
    # and Vary on Host so any compliant cache keys by host.
    def cache_discovery_metadata
      expires_in 1.hour # private — not shared-cacheable

      existing = response.headers["Vary"]
      response.headers["Vary"] =
        existing.present? ? "#{existing}, Host" : "Host"
    end

    # request.base_url honors X-Forwarded-* when the host has set
    # `config.action_dispatch.trusted_proxies` correctly — important
    # behind reverse proxies (Kamal, fly, Heroku, etc.) where
    # request.host_with_port would otherwise return the internal
    # container address.
    def issuer_url
      request.base_url
    end
  end
end
