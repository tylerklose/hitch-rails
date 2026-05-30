# frozen_string_literal: true

module Hitch
  # POST /oauth/revoke — revoke an access token (RFC 7009).
  # Per the RFC, returns 200 regardless of whether the token exists
  # so callers can't probe for valid tokens.
  class RevocationsController < Hitch::PublicEndpointController
    include Hitch::CorsSupport

    def create
      token_value = params[:token]
      if token_value.present?
        access_token = Hitch::AccessToken.find_by_token(token_value)
        access_token&.revoke!
      end

      head :ok
    end
  end
end
