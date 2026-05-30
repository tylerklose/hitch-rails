# frozen_string_literal: true

module Hitch
  # POST /oauth/register — Dynamic Client Registration (RFC 7591).
  # MCP clients register before starting the OAuth flow. The
  # client_name they send ("Claude Code", "ChatGPT", etc.) is
  # attacker-controllable — we persist it for audit fidelity but
  # consent UIs MUST NOT trust it for display (see authorize#new).
  class RegistrationsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport
    include Hitch::UriValidation

    def create
      # RFC 7591 §2: the authorization server is responsible for
      # enforcing its URI policy at registration. Without this, a
      # client could register `javascript:alert(1)` or
      # `http://attacker.test/cb` and try to use it at authorize.
      candidate_uris = Array.wrap(params[:redirect_uris]).select { |v| v.is_a?(String) }.compact_blank
      invalid = candidate_uris.reject { |uri| valid_redirect_uri?(uri) }
      if invalid.any?
        return oauth_error(
          "invalid_redirect_uri",
          "redirect_uris must be https://, or http://localhost / http://127.0.0.1 (RFC 8252). Rejected: #{invalid.join(', ')}"
        )
      end

      client = Hitch::Client.register!(
        client_id: SecureRandom.uuid,
        client_name: params[:client_name],
        redirect_uris: candidate_uris
      )

      render json: {
        client_id: client.client_id,
        client_id_issued_at: client.created_at.to_i,
        client_name: client.client_name,
        redirect_uris: client.redirect_uris,
        grant_types: [ "authorization_code" ],
        response_types: [ "code" ],
        scope: Hitch.configuration.supported_scopes.join(" "),
        token_endpoint_auth_method: "none"
      }, status: :created
    end
  end
end
