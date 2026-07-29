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
        token_endpoint_auth_methods_supported: [ "none" ],
        # RFC 9207 §3. Advertising this is a promise the authorization
        # response WILL carry `iss` — a conformant client treats an
        # advertised-but-absent `iss` as a hard failure and refuses the
        # code exchange. It is only ever true because
        # AuthorizationsController#build_redirect_uri appends it
        # unconditionally; the two must never be separated.
        authorization_response_iss_parameter_supported: issuer_is_https?
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

    # RFC 9207 §2: the `iss` value "MUST be a URL that uses the 'https'
    # scheme". Over plain http — development, or a deployment that never
    # terminated TLS — the value this server would emit is not a valid
    # issuer identifier, so promising conformance with it would be
    # promising something it cannot deliver.
    #
    # `iss` is still SENT in that case. The spec's validation table has
    # clients compare a present `iss` against the recorded issuer whether
    # or not support is advertised, so emitting it stays useful; only the
    # promise is withheld, which is what keeps a client from hard-failing
    # on a value it should never have been given.
    def issuer_is_https?
      issuer_url.to_s.start_with?("https://")
    end

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
  end
end
