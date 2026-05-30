# frozen_string_literal: true

module Hitch
  # POST /oauth/token — exchange auth code for access token.
  #
  # Public endpoint (no session auth — clients calling from CLI /
  # browser / desktop reach this without a Rails session). PKCE
  # verifier is the credential.
  class TokensController < Hitch::PublicEndpointController
    include Hitch::CorsSupport

    def create
      return oauth_error("invalid_request", "grant_type must be authorization_code") unless params[:grant_type] == "authorization_code"
      return oauth_error("invalid_request", "code is required") if params[:code].blank?
      return oauth_error("invalid_request", "code_verifier is required") if params[:code_verifier].blank?

      # Atomic find-and-consume. The row lock from FOR UPDATE is held
      # only for the life of the enclosing transaction, so the SELECT
      # and the consume_code! mutation must share one — otherwise the
      # lock releases the instant the SELECT returns and two parallel
      # exchanges of the same code could both proceed. Single-use is
      # ALSO enforced by the state transition (consume_code! sets
      # token_digest; the `pending` scope requires it NULL), but the
      # transaction makes the lock do real work and prevents a
      # last-writer-wins clobber.
      #
      # Lookup hashes the inbound code — the DB only stores SHA256
      # digests of auth codes, never the raw value.
      result = Hitch::AccessToken.transaction do
        token = Hitch::AccessToken
          .pending
          .lock("FOR UPDATE SKIP LOCKED")
          .find_by(authorization_code_digest: Digest::SHA256.hexdigest(params[:code]))
        next nil unless token

        # RFC 8707: if the client sends `resource` at token-exchange
        # time, it MUST match the resource the auth code was bound to.
        # Re-binding to a different audience is forbidden.
        if params[:resource].present? && token.resource_uri.present? && params[:resource] != token.resource_uri
          raise Hitch::AccessToken::OAuthError.new("invalid_target", "resource does not match the authorized resource")
        end

        { raw_token: token.consume_code!(params[:code_verifier]), scope: token.scopes }
      end

      return oauth_error("invalid_grant", "Invalid or expired authorization code") if result.nil?

      render json: {
        access_token: result[:raw_token],
        token_type: "Bearer",
        expires_in: Hitch.configuration.access_token_lifetime_seconds,
        scope: result[:scope]
      }
    rescue Hitch::AccessToken::OAuthError => e
      oauth_error(e.oauth_code, e.description)
    end

    # CORS preflight
    def preflight
      head :no_content
    end
  end
end
