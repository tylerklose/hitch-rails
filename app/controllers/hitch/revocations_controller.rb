# frozen_string_literal: true

module Hitch
  # POST /oauth/revoke — revoke an access token (RFC 7009).
  # Per the RFC, returns 200 regardless of whether the token exists
  # so callers can't probe for valid tokens.
  class RevocationsController < Hitch::PublicEndpointController
    MAX_REQUEST_BODY_BYTES = 16_384

    include Hitch::CorsSupport
    include Hitch::OauthFormAdmission

    def create
      return head :ok unless request.media_type == Hitch::OauthRequestParameters::FORM_MEDIA_TYPE

      token_value = oauth_parameters(:token, form_only: true)[:token]
      if token_value.present?
        access_token = Hitch::AccessToken.find_by_token(token_value)
        access_token&.revoke!
      end

      head :ok
    rescue Hitch::OauthRequestParameters::Invalid
      head :ok
    end

    private

    def reject_oversized_oauth_form_body!
      head :ok
    end
  end
end
