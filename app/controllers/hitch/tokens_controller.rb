# frozen_string_literal: true

module Hitch
  # POST /oauth/token — exchange auth code for access token.
  #
  # Public endpoint (no session auth — clients calling from CLI /
  # browser / desktop reach this without a Rails session). PKCE
  # verifier is the credential.
  class TokensController < Hitch::PublicEndpointController
    include Hitch::CorsSupport
    include Hitch::OauthFormAdmission
    include Hitch::UriValidation
    include Hitch::ClientResolution

    TOKEN_PARAMETER_NAMES = %i[
      grant_type
      code
      client_id
      client_secret
      code_verifier
      device_code
      resource
      redirect_uri
      refresh_token
      scope
    ].freeze

    def create
      unless request.media_type == Hitch::OauthRequestParameters::FORM_MEDIA_TYPE
        return oauth_error("invalid_request", "token requests must use application/x-www-form-urlencoded")
      end

      oauth = oauth_parameters(*TOKEN_PARAMETER_NAMES, form_only: true)
      case oauth[:grant_type]
      when "authorization_code" then authorization_code_grant(oauth)
      when "refresh_token" then refresh_token_grant(oauth)
      when Hitch::GrantTypes::DEVICE_CODE then device_code_grant(oauth)
      else
        oauth_error("invalid_request", "grant_type must be #{Hitch::GrantTypes.supported.join(' or ')}")
      end
    rescue Hitch::AccessToken::OAuthError => e
      oauth_error(e.oauth_code, e.description)
    end

    private

    def authorization_code_grant(oauth)
      return oauth_error("invalid_request", "code is required") if oauth[:code].blank?
      return oauth_error("invalid_request", "code_verifier is required") if oauth[:code_verifier].blank?
      unless Hitch::Pkce.valid_verifier?(oauth[:code_verifier])
        return invalid_authorization_code
      end
      if oauth[:redirect_uri].present? && !valid_redirect_uri?(oauth[:redirect_uri])
        return oauth_error("invalid_request", "redirect_uri is malformed")
      end

      resource = require_canonical_resource(oauth[:resource])
      return unless resource

      client_id = resolved_client_id(oauth)
      result = Hitch::AccessToken.exchange_authorization_code!(
        raw_code: oauth[:code],
        code_verifier: oauth[:code_verifier],
        client_id: client_id,
        resource_uri: resource,
        redirect_uri: oauth[:redirect_uri]
      )

      return invalid_authorization_code if result.nil?

      render_token(result)
    rescue Hitch::AccessToken::OAuthError => e
      # RFC 6819: distinct invalid_grant descriptions (wrong client,
      # wrong redirect_uri, PKCE) let an attacker probe a stolen code.
      # One public string; the oauth error code stays invalid_grant.
      return invalid_authorization_code if e.oauth_code == "invalid_grant"

      oauth_error(e.oauth_code, e.description)
    end

    def refresh_token_grant(oauth)
      return oauth_error("invalid_request", "refresh_token is required") if oauth[:refresh_token].blank?

      resource = require_canonical_resource(oauth[:resource])
      return unless resource

      client_id = resolved_client_id(oauth)
      result = Hitch::AccessToken.exchange_refresh_token!(
        raw_refresh_token: oauth[:refresh_token],
        client_id: client_id,
        resource_uri: resource,
        scopes: oauth[:scope]
      )

      return oauth_error("invalid_grant", "Invalid or expired refresh token") if result.nil?

      render_token(result)
    end

    # RFC 8628 §3.4. The model raises the §3.5 polling responses
    # (authorization_pending, slow_down, access_denied, expired_token) as
    # OAuthError, so they flow through the same rescue as every other grant.
    def device_code_grant(oauth)
      # Before any parameter or client validation: while the feature is off
      # this grant has exactly one answer (unsupported_grant_type, RFC 6749
      # §5.2), and no validation — client authentication included — runs
      # for it. The model repeats the gate for its own callers.
      unless Hitch.configuration.device_authorization_enabled
        return oauth_error("unsupported_grant_type", "Device authorization is not enabled")
      end
      return oauth_error("invalid_request", "device_code is required") if oauth[:device_code].blank?

      resource = require_canonical_resource(oauth[:resource])
      return unless resource

      authentication = resolved_client_authentication(oauth)
      result = Hitch::DeviceGrant.exchange_device_code!(
        raw_device_code: oauth[:device_code],
        client_id: authentication.client_id,
        resource_uri: resource,
        token_endpoint_auth_method: authentication.token_endpoint_auth_method
      )

      return oauth_error("invalid_grant", "Invalid or expired device code") if result.nil?

      render_token(result)
    end

    def client_authentication_realm
      "oauth/token"
    end

    # One shape for both grants. A refresh_token key is present only when the
    # feature is on, so a client cannot read the absence as an error.
    def render_token(result)
      body = {
        access_token: result[:raw_token],
        token_type: "Bearer",
        expires_in: Hitch.configuration.access_token_lifetime_seconds,
        scope: result[:scope]
      }
      body[:refresh_token] = result[:raw_refresh_token] if result[:raw_refresh_token].present?
      render json: body
    end

    # RFC 6749 section 5.1 requires token responses to be non-cacheable.
    # This hook runs in OauthFormAdmission before Rails instrumentation, so
    # successful exchanges and early admission failures get the same policy.
    def prepare_oauth_form_response!
      hitch_no_store!
    end

    def reject_oversized_oauth_form_body!
      oauth_error(
        "invalid_request",
        "token request body exceeds #{MAX_REQUEST_BODY_BYTES} bytes",
        413
      )
    end

    def invalid_authorization_code
      oauth_error("invalid_grant", "Invalid or expired authorization code")
    end
  end
end
