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
        authorization_endpoint: canonical_endpoint("/oauth/authorize"),
        token_endpoint: canonical_endpoint("/oauth/token"),
        revocation_endpoint: canonical_endpoint("/oauth/revoke"),
        response_types_supported: [ "code" ],
        grant_types_supported: Hitch::GrantTypes.supported,
        code_challenge_methods_supported: [ "S256" ],
        scopes_supported: Hitch.configuration.supported_scopes,
        token_endpoint_auth_methods_supported: Hitch::Client::TOKEN_ENDPOINT_AUTH_METHODS,
        # RFC 9207 §3. Advertising this is a promise the authorization
        # response WILL carry `iss` — a conformant client treats an
        # advertised-but-absent `iss` as a hard failure and refuses the
        # code exchange. It is only ever true because
        # AuthorizationsController#build_redirect_uri appends it
        # unconditionally; the two must never be separated.
        authorization_response_iss_parameter_supported: issuer_is_https?
      }.merge(dynamic_client_registration_advertisement)
        .merge(device_authorization_advertisement)
        .merge(client_id_metadata_advertisement)
    end

    def resource
      cache_discovery_metadata

      # RFC 9728 + 2026-07-28 MCP spec: PRM SHOULD include
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

    def dynamic_client_registration_advertisement
      return {} unless Hitch.configuration.dynamic_client_registration_enabled

      { registration_endpoint: canonical_endpoint("/oauth/register") }
    end

    # RFC 8628 §4. GrantTypes.supported adds the device grant urn under the
    # same flag, so the endpoint and the grant advertise and disappear
    # together.
    def device_authorization_advertisement
      return {} unless Hitch.configuration.device_authorization_enabled

      { device_authorization_endpoint: canonical_endpoint("/oauth/device_authorization") }
    end

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
    # unpleasant to debug remotely. A client that already accepted the
    # non-conformant http issuer from this same discovery document can
    # compare the two and pass. A stricter one may well reject the http
    # issuer during discovery and never reach the comparison — which is
    # the correct behaviour, and not something emitting `iss` either
    # causes or cures.
    #
    # Withholding the advertisement is what keeps this safe rather than
    # conformant. Per the spec's validation table, an advertised-but-
    # unusable value is what makes a conformant client hard-fail; a
    # present-but-unadvertised one it simply compares.
    def issuer_is_https?
      issuer_url.to_s.start_with?("https://")
    end

    def canonical_endpoint(path)
      "#{issuer_url}#{path}"
    end

    # Advertised only when the host has actually enabled CIMD. The flag
    # is what makes a conformant client stop falling back to Dynamic
    # Client Registration and send a document URL as its client_id (the
    # Ruby MCP SDK branches on exactly this), so advertising it while the
    # server would reject every such client_id turns a working DCR flow
    # into a broken one.
    def client_id_metadata_advertisement
      return {} unless Hitch.configuration.client_id_metadata_enabled

      { client_id_metadata_document_supported: true }
    end

    # Issuer URLs come from the configured canonical resource origin, not the
    # request. Keep discovery private and Vary on Host as defense in depth so
    # an ingress alias cannot cause one virtual host's response to be reused by
    # another application sharing a cache.
    def cache_discovery_metadata
      expires_in 1.hour # private — not shared-cacheable

      existing = response.headers["Vary"]
      response.headers["Vary"] =
        existing.present? ? "#{existing}, Host" : "Host"
    end
  end
end
