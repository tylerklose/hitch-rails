# frozen_string_literal: true

module Hitch
  # Base for the gem's PUBLIC OAuth endpoints (token, register, revoke,
  # metadata, /.well-known/*). These serve MCP clients (Claude.ai,
  # Claude Code, ChatGPT, Cursor, etc.) that are NOT browsers and have
  # NO host Rails session — the OAuth dance brings them to a session,
  # it doesn't start with one.
  #
  # Inherits from ActionController::Base directly (not the host's
  # ApplicationController) so the host's auth concern, browser-version
  # guard, layout, helpers, and other before-actions don't apply.
  # Session cookies / Rack-level middleware still flow because those
  # live outside the controller layer.
  #
  # The consent screen (AuthorizationsController) is deliberately NOT
  # in this category — it must integrate with the host's auth concern
  # to identify the user granting consent.
  class PublicEndpointController < ::ActionController::Base
    # These endpoints serve non-browser MCP clients (CLI / desktop /
    # server-to-server) that carry no Rails session and no CSRF token —
    # PKCE verifier or bearer-token possession is the credential, not a
    # session cookie. A host with CSRF protection enabled (the Rails
    # default via load_defaults) would otherwise reject every
    # POST /oauth/token, /oauth/register and /oauth/revoke with 422,
    # breaking the OAuth flow entirely. Skipping is safe: there is no
    # cookie-authenticated state here for a forged cross-site request to
    # act on. The consent screen (AuthorizationsController) is the only
    # session-backed POST and KEEPS forgery protection.
    skip_forgery_protection if respond_to?(:skip_forgery_protection)

    # Render an OAuth-formatted JSON error.
    def oauth_error(code, description, status = :bad_request)
      render json: { error: code, error_description: description }, status: status
    end

    # Guard against query-string array/hash coercion
    # (?client_id[]=a&client_id[]=b would otherwise become an Array).
    def scalar_param(key)
      value = params[key]
      value.is_a?(String) ? value.presence : nil
    end
  end
end
