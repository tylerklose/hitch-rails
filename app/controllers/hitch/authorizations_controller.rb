# frozen_string_literal: true

module Hitch
  # GET /oauth/authorize  — render consent screen
  # POST /oauth/authorize — issue authorization code
  #
  # Session-authenticated. Inherits the host's auth concern through
  # Hitch::ApplicationController. If current_principal is nil, the
  # controller redirects to Hitch.configuration.login_path (or
  # returns 401 if unset).
  #
  # RFC 8707 audience binding: the `resource` param sent by the client
  # is persisted on the access token at issue time and validated at
  # token-use time, satisfying the MCP authorization spec's audience MUST.
  #
  # The flow's HTTP-free reasoning — parameter validation, client and
  # redirect resolution, scope clamping, redirect construction — lives in
  # Hitch::AuthorizationRequest; this controller renders its decisions.
  class AuthorizationsController < Hitch::ApplicationController
    include Hitch::OauthFormAdmission

    AUTHORIZATION_PARAMETER_NAMES = %i[
      response_type
      client_id
      redirect_uri
      scope
      state
      code_challenge
      code_challenge_method
      resource
    ].freeze

    # The consent POST is a state-changing, session-authenticated
    # action, so it MUST be CSRF-protected. Declared here rather than
    # relying on the host's ApplicationController to have forgery
    # protection enabled — an API-only host, or one that disables it
    # app-wide, would otherwise leave Approve forgeable (an attacker
    # auto-approving an authorization in a logged-in victim's session).
    # The rendered consent form (form_with) carries the token, and
    # browsers send Sec-Fetch-Site — whichever the host's verification
    # strategy consults, legitimate submits are unaffected. Guarded: an
    # ActionController::API-derived host base doesn't define the macro,
    # and such a host can't serve the HTML consent screen anyway.
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    def new
      return require_principal! unless current_principal

      authorization = authorization_request(*AUTHORIZATION_PARAMETER_NAMES)
      return authorization_error(authorization) unless authorization.valid?

      @oauth_params = authorization.params
      @redirect_host = authorization.redirect_host
      @client_name = authorization.display_client_name
      @brand_name = Hitch.configuration.brand_name
      @resource = authorization.resource
      @localhost_only_client = authorization.localhost_only_client?
      # Show the user exactly what they're approving (clamped to the
      # server allowlist — never echo an unsupported requested scope).
      @scopes = authorization.granted_scopes
    end

    def create
      return require_principal! unless current_principal

      authorization = authorization_request(*AUTHORIZATION_PARAMETER_NAMES, :decision)
      return authorization_error(authorization) unless authorization.valid?

      # RFC 6749 §4.1.2.1: the user declining is reported to the validated
      # redirect_uri as access_denied — with iss, like every redirect.
      if authorization.deny?
        return redirect_to_client(
          authorization.redirect_uri_for(error: "access_denied", state: authorization.state)
        )
      end

      token = Hitch::AccessToken.create_authorization!(
        principal: current_principal,
        client_id: authorization.client_id,
        client_name: authorization.audit_client_name,
        redirect_uri: authorization.redirect_uri,
        code_challenge: authorization.code_challenge,
        code_challenge_method: authorization.code_challenge_method,
        resource_uri: authorization.resource,
        scopes: authorization.granted_scopes
      )

      redirect_to_client(
        authorization.redirect_uri_for(code: token.raw_authorization_code, state: authorization.state)
      )
    end

    private

    def authorization_request(*names)
      Hitch::AuthorizationRequest.new(
        oauth_parameters(*names),
        principal: current_principal
      )
    end

    def authorization_error(authorization)
      error = authorization.error
      oauth_error(error.code, error.description, error.status)
    end

    def reject_oversized_oauth_form_body!
      oauth_error(
        "invalid_request",
        "authorization request body exceeds #{MAX_REQUEST_BODY_BYTES} bytes",
        :content_too_large
      )
    end

    def preserve_oauth_authenticity_token?
      true
    end

    # Action Controller's ordinary redirect helper emits the complete Location
    # through `redirect_to.action_controller`; Rails' log subscriber then
    # writes the one-time authorization code in plaintext. The destination has
    # already passed exact registered-URI validation, so construct the 302
    # directly and keep the credential out of redirect instrumentation.
    def redirect_to_client(location)
      hitch_no_store!
      response.headers["Location"] = location
      head :found
    end
  end
end
