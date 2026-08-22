# frozen_string_literal: true

module Hitch
  # POST /oauth/revoke — revoke an access token (RFC 7009).
  # Per the RFC, returns 200 regardless of whether the token exists
  # so callers can't probe for valid tokens.
  class RevocationsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport
    include Hitch::OauthFormAdmission

    def create
      return head :ok unless request.media_type == Hitch::OauthRequestParameters::FORM_MEDIA_TYPE

      token_value = oauth_parameters(:token, form_only: true)[:token]
      revoke(token_value) if token_value.present?

      head :ok
    rescue Hitch::OauthRequestParameters::Invalid
      head :ok
    end

    private

    # RFC 7009 §2.1: the endpoint takes either token type. An access token
    # revokes itself; a refresh token revokes the family it belongs to,
    # because the trust a human granted at the consent screen is the family,
    # and revoking one link would leave the rest of the chain usable.
    def revoke(token_value)
      access_token = Hitch::AccessToken.find_by_token(token_value)
      return access_token.revoke! if access_token

      refresh_token = Hitch::AccessToken.find_by_refresh_token(token_value)
      Hitch::AccessToken.revoke_family!(refresh_token.family_id) if refresh_token
    end

    def reject_oversized_oauth_form_body!
      head :ok
    end
  end
end
