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
    # scheme". Over plain http the value this server emits is therefore
    # not a valid issuer identifier, and withholding the advertisement
    # does not make it one.
    #
    # Be clear about what this is: over http the server is NOT conformant
    # here, and that is deliberate development compatibility, not a
    # design. It is also not the first deviation on that path — MCP
    # 2026-07-28 requires every authorization server endpoint be served
    # over HTTPS, so an http deployment is already outside the spec and
    # the issuer scheme is the smaller of its problems.
    #
    # `iss` is still emitted over http rather than suppressed, so that a
    # local development flow exercises the same path as production. The
    # alternative — omit it below https — means the parameter silently
    # appears for the first time on deploy, in a security control that is
    # unpleasant to debug remotely. Nothing breaks: the client compares
    # it against the issuer from the same discovery document, which is
    # equally http, so the comparison passes.
    #
    # Withholding the advertisement is what keeps this safe rather than
    # conformant. Per the spec's validation table, an advertised-but-
    # unusable value is what makes a conformant client hard-fail; a
    # present-but-unadvertised one it simply compares.
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
