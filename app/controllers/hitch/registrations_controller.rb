# frozen_string_literal: true

module Hitch
  # POST /oauth/register — Dynamic Client Registration (RFC 7591).
  # MCP clients register before starting the OAuth flow. The
  # client_name they send ("Claude Code", "ChatGPT", etc.) is
  # attacker-controllable — we persist it for audit fidelity but
  # consent UIs MUST NOT trust it for display (see authorize#new).
  class RegistrationsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport
    include Hitch::RegistrationAdmission
    include Hitch::UriValidation

    def create
      # RegistrationAdmission has already parsed one bounded JSON object
      # and installed it here — the action never runs otherwise.
      metadata = request.request_parameters

      # RFC 7591 §2: the authorization server is responsible for
      # enforcing its URI policy at registration. Without this, a
      # client could register `javascript:alert(1)` or
      # `http://attacker.test/cb` and try to use it at authorize.
      normalized = normalized_registration_metadata(metadata)
      return if performed?

      candidate_uris = normalized.fetch(:redirect_uris)
      invalid = candidate_uris.reject { |uri| valid_redirect_uri?(uri) }
      if invalid.any?
        return oauth_error(
          "invalid_redirect_uri",
          "redirect_uris must contain only https URIs or RFC 8252 loopback http URIs"
        )
      end

      auth_method = optional_string_metadata(metadata, "token_endpoint_auth_method") || "none"
      return if performed?

      unless Hitch::Client::TOKEN_ENDPOINT_AUTH_METHODS.include?(auth_method)
        return oauth_error(
          "invalid_client_metadata",
          "token_endpoint_auth_method must be none or client_secret_basic"
        )
      end

      application_type = optional_string_metadata(metadata, "application_type")
      return if performed?

      client, client_secret = register_client(
        auth_method,
        client_name: metadata["client_name"],
        redirect_uris: candidate_uris,
        application_type: application_type
      )

      response_body = {
        client_id: client.client_id,
        client_id_issued_at: client.created_at.to_i,
        client_name: client.client_name,
        redirect_uris: client.redirect_uris,
        grant_types: [ "authorization_code" ],
        response_types: [ "code" ],
        scope: Hitch.configuration.supported_scopes.join(" "),
        token_endpoint_auth_method: client.token_endpoint_auth_method
      }.merge(
        # Echo what was actually STORED, not what was sent — RFC 7591
        # §3.2.1 makes the response the authoritative record of registered
        # metadata, so a client that sent an unrecognized value can tell
        # it was dropped by diffing its request against this response.
        # (Not that it reads as an explicit rejection: §2 defaults an
        # absent application_type to "web", so silence means the default,
        # not "you declared nothing".)
        #
        # Omitted rather than sent as null when undeclared. Scoped to this
        # one key deliberately: a blanket `.compact` would silently drop
        # any future nullable field, and §3.2.1 makes some of them —
        # `client_secret_expires_at` when a secret is issued — REQUIRED.
        client.application_type ? { application_type: client.application_type } : {}
      )
      if client_secret
        response_body.merge!(
          client_secret: client_secret,
          client_secret_issued_at: client.client_secret_issued_at.to_i,
          client_secret_expires_at: 0
        )
      end

      render json: response_body, status: :created
    end

    private

    def normalized_registration_metadata(metadata)
      Hitch::Client.normalize_registration_metadata!(
        client_name: metadata["client_name"],
        redirect_uris: metadata["redirect_uris"]
      )
    rescue Hitch::Client::InvalidRegistrationMetadata
      oauth_error(
        "invalid_client_metadata",
        "client_name and redirect_uris must satisfy the documented size and shape limits"
      )
      nil
    end

    def optional_string_metadata(metadata, key)
      return unless metadata.key?(key)
      return metadata[key] if metadata[key].is_a?(String)

      oauth_error("invalid_client_metadata", "#{key} must be a string")
      nil
    end

    # Returns [client, client_secret]; the secret is nil for public clients.
    # Client.register! returns the record and register_confidential! returns
    # one-time Credentials (its documented contract), so this is where the
    # two shapes become one.
    def register_client(auth_method, client_name:, redirect_uris:, application_type:)
      attributes = {
        client_id: SecureRandom.uuid,
        client_name: client_name,
        redirect_uris: redirect_uris,
        # Recorded, never enforced: gating loopback redirects on a
        # declaration would break clients that omit this metadata.
        application_type: application_type
      }

      if auth_method == "client_secret_basic"
        credentials = Hitch::Client.register_confidential!(**attributes)
        [ credentials.client, credentials.client_secret ]
      else
        [ Hitch::Client.register!(**attributes), nil ]
      end
    end
  end
end
