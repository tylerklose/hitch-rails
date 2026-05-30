# frozen_string_literal: true

module Hitch
  # Streamable HTTP response shaping + bearer-token auth for a host's MCP
  # JSON-RPC endpoint (POST /mcp). The host owns the route and the tool
  # dispatch; the gem owns the protocol envelope so no consumer re-trips
  # the spec contract — the 202-for-notifications rule a strict client
  # (Grok) enforces, the bearer auth, and the WWW-Authenticate discovery
  # challenge. All three are RFC-fixed and identical across consumers.
  #
  # Use a DEDICATED controller for /mcp: `skip_forgery_protection` is
  # controller-wide, so don't mix MCP and browser actions in one class.
  #
  #   class MCPServerController < ApplicationController
  #     include Hitch::ServerEndpoint
  #     before_action :require_mcp_token!
  #
  #     def create
  #       # mcp_token is the validated Hitch::AccessToken
  #       # (mcp_token.principal is the resource owner). Build your MCP
  #       # server with your tools and hand it the raw body; the gem only
  #       # shapes the HTTP response.
  #       server = build_mcp_server(mcp_token.principal) # host-specific
  #       render_mcp_response(server.handle_json(request.raw_post))
  #     end
  #   end
  #
  # Requires Hitch.configuration.resource_uri to be set: tokens are
  # validated against it (RFC 8707 audience binding) and unbound or
  # mismatched tokens are rejected with 401.
  module ServerEndpoint
    extend ActiveSupport::Concern

    included do
      # MCP clients are non-browser, sessionless, and send no CSRF token —
      # bearer-token possession is the credential. Without this, a host
      # with CSRF protection enabled (the Rails default via load_defaults)
      # would reject every JSON-RPC POST with 422. Guarded for an
      # ActionController::API-derived host base.
      skip_forgery_protection if respond_to?(:skip_forgery_protection)
    end

    # The AccessToken validated by require_mcp_token!; nil before it runs
    # or after an auth failure.
    attr_reader :mcp_token

    private

    # Shape the HTTP response per the MCP Streamable HTTP spec:
    #   - a JSON-RPC request (has id, expects a result) → 200 +
    #     application/json (the body ::MCP::Server#handle_json returns)
    #   - a notification / response (no reply) → 202 Accepted, no body
    #     (handle_json returns nil for these)
    #
    # Rendering 200 + an empty body for a notification is tolerated by
    # Claude/ChatGPT/Codex but trips strict clients: Grok treats the
    # handshake as malformed, loops back to `initialize`, and never calls
    # tools/list. `session_id:` is optional and only for a future stateful
    # consumer — the gem never mints one (stateless is spec-valid).
    def render_mcp_response(response_body, session_id: nil)
      response.headers["Mcp-Session-Id"] = session_id if session_id.present?

      if response_body.blank?
        head :accepted
      else
        # handle_json returns an already-serialized JSON string, so render
        # it verbatim — `render json:` would double-encode it.
        render plain: response_body, content_type: "application/json"
      end
    end

    # before_action: authenticate the inbound MCP request by bearer token.
    # On success sets `mcp_token` and proceeds; on failure renders the 401
    # discovery challenge and halts. Scope *authorization* is the host's
    # call after this (e.g. `mcp_token.has_scope?("write")`).
    def require_mcp_token!
      access_token = Hitch::AccessToken.find_by_token(bearer_token)

      if access_token&.valid_for_resource?(Hitch.configuration.resource_uri)
        @mcp_token = access_token
      else
        mcp_unauthorized!
      end
    end

    # MCP spec MUST: a 401 carries a WWW-Authenticate header pointing
    # clients at the Protected Resource Metadata document so they can
    # (re)discover the authorization server (RFC 9728 §5.1, RFC 6750 §3).
    # Without it, MCP clients can't auto-recover after token expiry or a
    # server migration.
    def mcp_unauthorized!
      response.headers["WWW-Authenticate"] = bearer_challenge
      head :unauthorized
    end

    def bearer_token
      request.headers["Authorization"]&.delete_prefix("Bearer ")&.strip
    end

    def bearer_challenge
      metadata_url = "#{request.base_url}/.well-known/oauth-protected-resource"
      scope = Array.wrap(Hitch.configuration.supported_scopes).join(" ")
      %(Bearer resource_metadata="#{metadata_url}", scope="#{scope}")
    end
  end
end
