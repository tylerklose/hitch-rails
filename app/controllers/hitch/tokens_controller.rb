# frozen_string_literal: true

module Hitch
  # POST /oauth/token — exchange auth code for access token.
  #
  # Public endpoint (no session auth — clients calling from CLI /
  # browser / desktop reach this without a Rails session). PKCE
  # verifier is the credential.
  class TokensController < Hitch::PublicEndpointController
    MAX_REQUEST_BODY_BYTES = 16_384

    include Hitch::CorsSupport
    include Hitch::OauthFormAdmission
    include Hitch::UriValidation

    TOKEN_PARAMETER_NAMES = %i[
      grant_type
      code
      client_id
      client_secret
      code_verifier
      resource
      redirect_uri
    ].freeze

    def create
      unless request.media_type == Hitch::OauthRequestParameters::FORM_MEDIA_TYPE
        return oauth_error("invalid_request", "token requests must use application/x-www-form-urlencoded")
      end

      oauth = oauth_parameters(*TOKEN_PARAMETER_NAMES, form_only: true)
      return oauth_error("invalid_request", "grant_type must be authorization_code") unless oauth[:grant_type] == "authorization_code"
      return oauth_error("invalid_request", "code is required") if oauth[:code].blank?
      return oauth_error("invalid_request", "code_verifier is required") if oauth[:code_verifier].blank?
      unless Hitch::Pkce.valid_verifier?(oauth[:code_verifier])
        return oauth_error("invalid_grant", "Invalid or expired authorization code")
      end
      if oauth[:redirect_uri].present? && !valid_redirect_uri?(oauth[:redirect_uri])
        return oauth_error("invalid_request", "redirect_uri is malformed")
      end

      resource = canonical_resource(oauth[:resource])
      return unless resource

      client_id = Hitch::ClientAuthentication.resolve(
        request: request,
        body_client_id: oauth[:client_id],
        body_secret_present: oauth[:client_secret].present?
      )
      result = Hitch::AccessToken.exchange_authorization_code!(
        raw_code: oauth[:code],
        code_verifier: oauth[:code_verifier],
        client_id: client_id,
        resource_uri: resource
      )

      return oauth_error("invalid_grant", "Invalid or expired authorization code") if result.nil?

      render json: {
        access_token: result[:raw_token],
        token_type: "Bearer",
        expires_in: Hitch.configuration.access_token_lifetime_seconds,
        scope: result[:scope]
      }
    rescue Hitch::ClientAuthentication::Invalid => error
      response.headers["WWW-Authenticate"] = 'Basic realm="oauth/token"' if error.http_status == :unauthorized
      oauth_error(error.oauth_code, error.message, error.http_status)
    rescue Hitch::AccessToken::OAuthError => e
      oauth_error(e.oauth_code, e.description)
    end

    private

    # RFC 6749 section 5.1 requires token responses to be non-cacheable.
    # This hook runs in OauthFormAdmission before Rails instrumentation, so
    # successful exchanges and early admission failures get the same policy.
    def prepare_oauth_form_response!
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
    end

    def reject_oversized_oauth_form_body!
      oauth_error(
        "invalid_request",
        "token request body exceeds #{MAX_REQUEST_BODY_BYTES} bytes",
        :content_too_large
      )
    end

    def canonical_resource(value)
      if value.blank?
        oauth_error("invalid_target", "resource is required")
        return nil
      end

      allow_loopback = Rails.env.development? || Rails.env.test?
      requested = Hitch::ResourceUri.canonicalize!(value, allow_loopback_http: allow_loopback)
      configured = Hitch::ResourceUri.canonicalize!(
        Hitch.configuration.resource_uri,
        allow_loopback_http: allow_loopback
      )
      unless requested == configured
        oauth_error("invalid_target", "resource does not identify this MCP server")
        return nil
      end

      requested
    rescue Hitch::ResourceUri::Invalid => error
      oauth_error("invalid_target", error.message)
      nil
    end
  end
end
