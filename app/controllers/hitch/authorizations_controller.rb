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
  class AuthorizationsController < Hitch::ApplicationController
    include Hitch::UriValidation

    # The consent POST is a state-changing, session-authenticated
    # action, so it MUST be CSRF-protected. Declared here rather than
    # relying on the host's ApplicationController to have forgery
    # protection enabled — an API-only host, or one that disables it
    # app-wide, would otherwise leave Approve forgeable (an attacker
    # auto-approving an authorization in a logged-in victim's session).
    # The rendered consent form (form_with) carries the token, so
    # legitimate submits are unaffected. Guarded: an
    # ActionController::API-derived host base doesn't define the macro,
    # and such a host can't serve the HTML consent screen anyway.
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)

    def new
      return require_principal! unless current_principal

      oauth = extract_oauth_params
      return oauth_error("invalid_request", "redirect_uri is required") if oauth[:redirect_uri].blank?
      return oauth_error("invalid_request", "Invalid redirect_uri") unless valid_redirect_uri?(oauth[:redirect_uri])
      return oauth_error("invalid_target", "resource must be an absolute URI") if oauth[:resource].present? && !valid_resource_uri?(oauth[:resource])

      if (err = client_redirect_error(oauth[:client_id], oauth[:redirect_uri]))
        return oauth_error(*err)
      end

      @oauth_params = oauth
      @redirect_host = redirect_host(oauth[:redirect_uri])
      @client_name = friendly_client_name(oauth[:redirect_uri]) || @redirect_host || "An application"
      @brand_name = Hitch.configuration.brand_name
      @resource = oauth[:resource]
      # Show the user exactly what they're approving (clamped to the
      # server allowlist — never echo an unsupported requested scope).
      @scopes = granted_scopes(oauth[:scope])
    end

    def create
      return require_principal! unless current_principal

      oauth = extract_oauth_params
      return oauth_error("invalid_request", "redirect_uri is required") if oauth[:redirect_uri].blank?
      return oauth_error("invalid_request", "Invalid redirect_uri") unless valid_redirect_uri?(oauth[:redirect_uri])
      return oauth_error("invalid_request", "code_challenge is required") if oauth[:code_challenge].blank?
      return oauth_error("invalid_request", "code_challenge_method must be S256") unless oauth[:code_challenge_method] == "S256"
      return oauth_error("invalid_target", "resource must be an absolute URI") if oauth[:resource].present? && !valid_resource_uri?(oauth[:resource])

      if (err = client_redirect_error(oauth[:client_id], oauth[:redirect_uri]))
        return oauth_error(*err)
      end

      mcp_client = Hitch::Client.find_by(client_id: oauth[:client_id])

      token = Hitch::AccessToken.create_authorization!(
        principal: current_principal,
        client_id: oauth[:client_id],
        client_name: mcp_client&.client_name || friendly_client_name(oauth[:redirect_uri]) || "Unknown",
        redirect_uri: oauth[:redirect_uri],
        code_challenge: oauth[:code_challenge],
        code_challenge_method: oauth[:code_challenge_method],
        resource_uri: resource_for_token(oauth[:resource]),
        # Clamp to the server allowlist — a client cannot self-grant a
        # scope the server doesn't support (RFC 6749 §3.3).
        scopes: granted_scopes(oauth[:scope])
      )

      redirect_to build_redirect_uri(oauth[:redirect_uri], code: token.raw_authorization_code, state: oauth[:state]),
                  allow_other_host: true
    end

    private

    def extract_oauth_params
      {
        redirect_uri: scalar_param(:redirect_uri),
        state: scalar_param(:state),
        client_id: scalar_param(:client_id),
        code_challenge: scalar_param(:code_challenge),
        code_challenge_method: scalar_param(:code_challenge_method),
        scope: scalar_param(:scope),
        resource: scalar_param(:resource)
      }
    end

    # If the client supplied a `resource` parameter, bind the token to
    # it (RFC 8707). If absent, fall back to the host's configured
    # resource_uri so the MCP server's audience check has something to
    # validate against. If neither is set, the token is issued
    # unbound and downstream resource checks will reject it — that's
    # the safe default per spec.
    def resource_for_token(client_resource)
      client_resource.presence || Hitch.configuration.resource_uri
    end

    def default_scope
      Array.wrap(Hitch.configuration.supported_scopes).first || "mcp"
    end

    # Intersect the requested scope with the server's supported_scopes
    # allowlist. A client can only ever receive scopes the server
    # actually supports — requesting "admin" against a server that
    # supports ["mcp"] yields "mcp", never "admin" (RFC 6749 §3.3, the
    # AS MAY issue a token with a narrower scope than requested). If
    # the intersection is empty, fall back to the default scope so the
    # token is never issued scopeless.
    def granted_scopes(requested)
      supported = Array.wrap(Hitch.configuration.supported_scopes).map(&:to_s)
      asked = requested.to_s.split(/\s+/).reject(&:blank?)
      granted = asked & supported
      granted.presence&.join(" ") || default_scope
    end

    # redirect_uri MUST be validated against a registered client on
    # EVERY authorize request. There is no unauthenticated/unregistered
    # path: OAuth 2.1 §4.1.1 requires client_id, and RFC 9700 §4.1.3
    # requires the redirect be matched against the client's
    # pre-registered set. Clients without prior registration obtain a
    # client_id via Dynamic Client Registration (/oauth/register)
    # first. Returns nil when valid, or an [error, description] pair.
    def client_redirect_error(client_id, redirect_uri)
      return [ "invalid_request", "client_id is required" ] if client_id.blank?

      mcp_client = Hitch::Client.find_by(client_id: client_id)
      return [ "invalid_client", "Unknown client_id — register via /oauth/register first" ] if mcp_client.nil?
      return [ "invalid_request", "client has no registered redirect_uris" ] if mcp_client.redirect_uris.blank?

      # RFC 8252 port-agnostic match for loopback; exact otherwise.
      return nil if mcp_client.redirect_uris.any? { |registered| redirect_uri_matches?(registered, redirect_uri) }

      [ "invalid_request", "redirect_uri not registered for this client" ]
    end

    def redirect_host(uri)
      URI.parse(uri).host
    rescue URI::InvalidURIError
      nil
    end

    def friendly_client_name(redirect_uri)
      host = URI.parse(redirect_uri).host
      return nil if host.blank?

      case host
      when "claude.ai"                                                 then "Claude"
      when /\A([\w-]+\.)?chatgpt\.com\z/, /\A([\w-]+\.)?openai\.com\z/ then "ChatGPT"
      when /\A([\w-]+\.)?cursor\.(com|sh)\z/                           then "Cursor"
      when /\A([\w-]+\.)?windsurf\.com\z/                              then "Windsurf"
      when /\A([\w-]+\.)?gemini\.google\.com\z/                        then "Gemini"
      when "grok.com", /\A([\w-]+\.)?x\.ai\z/                          then "Grok"
      when "localhost", "127.0.0.1"                                    then "Local Development"
      end
    rescue URI::InvalidURIError
      nil
    end

    def build_redirect_uri(base_uri, code:, state:)
      uri = URI.parse(base_uri)
      query_params = URI.decode_www_form(uri.query || "")
      query_params << [ "code", code ]
      query_params << [ "state", state ] if state.present?
      uri.query = URI.encode_www_form(query_params)
      uri.to_s
    end

    def require_principal!
      # Remember where the user was headed so the host's auth flow returns
      # them to the consent screen after login. Rails 8's built-in
      # authentication reads session[:return_to_after_authenticating] in
      # after_authentication_url; normally its own require_authentication
      # callback sets this, but the consent controller skips that callback
      # (see ApplicationController) and redirects to login_path itself, so
      # we set the return location here. Harmless for hosts that never read
      # the key. Only meaningful on the GET consent render — a POST without
      # a session isn't a real flow.
      session[:return_to_after_authenticating] = request.url if request.get?

      path = Hitch.configuration.login_path
      target = path.respond_to?(:call) ? path.call(request) : path

      if target.present?
        redirect_to target, allow_other_host: true
      else
        render plain: "Authentication required", status: :unauthorized
      end
    end
  end
end
