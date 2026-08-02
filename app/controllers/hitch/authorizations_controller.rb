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
    MAX_REQUEST_BODY_BYTES = 16_384

    include Hitch::OauthFormAdmission
    include Hitch::UriValidation

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
    # The rendered consent form (form_with) carries the token, so
    # legitimate submits are unaffected. Guarded: an
    # ActionController::API-derived host base doesn't define the macro,
    # and such a host can't serve the HTML consent screen anyway.
    protect_from_forgery with: :exception if respond_to?(:protect_from_forgery)
    def new
      return require_principal! unless current_principal

      oauth = valid_authorization_request(extract_oauth_params)
      return unless oauth

      if (err = client_redirect_error(oauth[:client_id], oauth[:redirect_uri]))
        return oauth_error(*err)
      end

      @oauth_params = oauth
      @redirect_host = redirect_host(oauth[:redirect_uri])
      @client_name = friendly_client_name(oauth[:redirect_uri]) || @redirect_host || "An application"
      @brand_name = Hitch.configuration.brand_name
      @resource = oauth[:resource]
      @localhost_only_client = localhost_only_client?(oauth[:client_id])
      # Show the user exactly what they're approving (clamped to the
      # server allowlist — never echo an unsupported requested scope).
      @scopes = granted_scopes(oauth[:scope])
    end

    def create
      return require_principal! unless current_principal

      oauth = valid_authorization_request(extract_oauth_params)
      return unless oauth

      if (err = client_redirect_error(oauth[:client_id], oauth[:redirect_uri]))
        return oauth_error(*err)
      end

      token = Hitch::AccessToken.create_authorization!(
        principal: current_principal,
        client_id: oauth[:client_id],
        client_name: declared_client_name(oauth[:client_id]) || friendly_client_name(oauth[:redirect_uri]) || "Unknown",
        redirect_uri: oauth[:redirect_uri],
        code_challenge: oauth[:code_challenge],
        code_challenge_method: oauth[:code_challenge_method],
        resource_uri: oauth[:resource],
        # Clamp to the server allowlist — a client cannot self-grant a
        # scope the server doesn't support (RFC 6749 §3.3).
        scopes: granted_scopes(oauth[:scope])
      )

      redirect_with_authorization_code(
        build_redirect_uri(oauth[:redirect_uri], code: token.raw_authorization_code, state: oauth[:state])
      )
    end

    private

    def extract_oauth_params
      oauth_parameters(*AUTHORIZATION_PARAMETER_NAMES)
    end

    def valid_authorization_request(oauth)
      if oauth[:response_type].blank?
        oauth_error("invalid_request", "response_type is required")
        return false
      end
      unless oauth[:response_type] == "code"
        oauth_error("unsupported_response_type", "response_type must be code")
        return false
      end
      if oauth[:client_id].blank?
        oauth_error("invalid_request", "client_id is required")
        return false
      end
      if oauth[:redirect_uri].blank?
        oauth_error("invalid_request", "redirect_uri is required")
        return false
      end
      unless valid_redirect_uri?(oauth[:redirect_uri])
        oauth_error("invalid_request", "Invalid redirect_uri")
        return false
      end
      if oauth[:code_challenge].blank?
        oauth_error("invalid_request", "code_challenge is required")
        return false
      end
      unless Hitch::Pkce.valid_s256_challenge?(oauth[:code_challenge])
        oauth_error("invalid_request", "code_challenge must be a 43-character S256 value")
        return false
      end
      unless oauth[:code_challenge_method] == "S256"
        oauth_error("invalid_request", "code_challenge_method must be S256")
        return false
      end

      resource = canonical_resource(oauth[:resource])
      resource ? oauth.merge(resource: resource).freeze : false
    end

    def canonical_resource(value)
      if value.blank?
        oauth_error("invalid_target", "resource is required")
        return false
      end

      requested = Hitch::ResourceUri.canonicalize!(
        value,
        allow_loopback_http: Rails.env.development? || Rails.env.test?
      )
      configured = Hitch::ResourceUri.canonicalize!(
        Hitch.configuration.resource_uri,
        allow_loopback_http: Rails.env.development? || Rails.env.test?
      )
      unless requested == configured
        oauth_error("invalid_target", "resource does not identify this MCP server")
        return false
      end

      requested
    rescue Hitch::ResourceUri::Invalid => error
      oauth_error("invalid_target", error.message)
      false
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

    def default_scope
      Hitch.configuration.supported_scopes.first
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

      registered = registered_redirect_uris(client_id)
      return [ "invalid_client", unknown_client_message(client_id) ] if registered.nil?
      return [ "invalid_request", "client has no usable redirect_uris" ] if registered.blank?

      # RFC 8252 port-agnostic match for loopback; exact otherwise.
      return nil if registered.any? { |candidate| redirect_uri_matches?(candidate, redirect_uri) }

      [ "invalid_request", "redirect_uri not registered for this client" ]
    end

    # The client's declared redirect_uris, from whichever registration
    # scheme its client_id belongs to. nil means "no such client";
    # an empty array means "a client, but nothing usable to redirect to".
    #
    # An https client_id is a Client ID Metadata Document reference
    # (MCP 2026-07-28); anything else is an opaque DCR client_id. The two
    # cannot collide, so both schemes run side by side and DCR keeps
    # working unchanged.
    def registered_redirect_uris(client_id)
      return Hitch::Client.find_by(client_id: client_id)&.redirect_uris unless
        Hitch::ClientIdMetadata.reference?(client_id)

      # The gem's own https-or-loopback policy (RFC 8252) still applies.
      # DCR enforces it at registration time; a metadata document never
      # passes through registration, so it is enforced here instead —
      # otherwise CIMD would be a way to bypass a check DCR clients face.
      Hitch::ClientIdMetadata.resolve(client_id, actor: rate_limit_actor)
        &.redirect_uris
        &.select { |candidate| valid_redirect_uri?(candidate) }
    end

    # MCP 2026-07-28 security considerations: a Client ID Metadata
    # Document "cannot prevent localhost URL impersonation by itself",
    # and authorization servers SHOULD warn when a client's redirect
    # URIs are localhost-only. Anyone can host a document claiming any
    # name and point it at a loopback port — the user's own machine is
    # then the destination, and nothing about the document proves which
    # program is listening there.
    def localhost_only_client?(client_id)
      return false unless Hitch::ClientIdMetadata.reference?(client_id)

      declared = registered_redirect_uris(client_id)
      return false if declared.blank?

      declared.all? { |candidate| loopback_redirect_uri?(candidate) }
    end

    def loopback_redirect_uri?(candidate)
      parsed = URI.parse(candidate)
      parsed.scheme == "http" && loopback_host?(parsed.host)
    rescue URI::InvalidURIError
      false
    end

    # Identifies the principal driving a metadata fetch, for per-actor
    # rate limiting. Counting per actor is what bounds amplification:
    # neither of the tricks that defeat negative caching — a wildcard DNS
    # record giving unlimited distinct hosts, or a responsive host
    # answering 404 for unlimited distinct URLs — changes who is asking.
    #
    # Class name included so two principal models cannot collide on an
    # integer id. nil when unauthenticated, which cannot happen on this
    # path (both actions bail to require_principal! first) but keeps the
    # limiter honest if that ever changes.
    def rate_limit_actor
      return nil unless current_principal.respond_to?(:id)

      "#{current_principal.class.name}:#{current_principal.id}"
    end

    def unknown_client_message(client_id)
      if Hitch::ClientIdMetadata.reference?(client_id)
        "Could not resolve a client metadata document at that client_id"
      else
        "Unknown client_id — register via /oauth/register first"
      end
    end

    # The name the client claims for itself, from either registration
    # scheme. Attacker-controllable in both — anyone can POST any
    # client_name to /oauth/register, and anyone can host a metadata
    # document saying anything. Persisted on the token for audit
    # fidelity; the consent screen derives its display name from the
    # verified redirect_uri host instead (see friendly_client_name).
    def declared_client_name(client_id)
      if Hitch::ClientIdMetadata.reference?(client_id)
        Hitch::ClientIdMetadata.resolve(client_id, actor: rate_limit_actor)&.client_name
      else
        Hitch::Client.find_by(client_id: client_id)&.client_name
      end
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

    # RFC 9207: the authorization response MUST identify the issuer that
    # produced it, so a client registered with more than one
    # authorization server can detect a mix-up before redeeming the code.
    #
    # The value MUST be byte-identical to the `issuer` advertised at
    # /.well-known/oauth-authorization-server — clients compare them with
    # an exact string comparison — which is why both come from the shared
    # Hitch::IssuerUrl helper rather than two independent derivations.
    # Appended unconditionally: the metadata document promises it via
    # `authorization_response_iss_parameter_supported`, and a client that
    # sees that promise unfulfilled refuses the exchange. Any future
    # error path that redirects to the client (rather than rendering
    # JSON, as oauth_error does today) MUST carry `iss` as well — RFC
    # 9207 §2 covers error responses too.
    #
    # Response parameters are stripped from the inbound query before
    # being set. This is defense in depth, not the primary control —
    # Hitch::UriValidation#redirect_uri_matches? compares the query, so
    # an unregistered `?iss=…` is rejected before reaching this method.
    # What it covers is the case exact matching cannot: a client that
    # legitimately REGISTERED a query string containing a response
    # parameter. There the match succeeds, and without this the response
    # would carry the parameter twice — which copy wins is a property of
    # the client's query parser, and first-wins parsers (URLSearchParams,
    # Go's Query().Get, Python's parse_qs) would read the registered
    # value and route the code exchange at whatever token endpoint it
    # names. That is the mix-up RFC 9207 exists to prevent, and the
    # discovery document promises clients that defense. `code` and
    # `state` are stripped for the same reason: mandatory S256 PKCE
    # blunts those today, but the injection primitive is identical.
    #
    # The error parameters (RFC 6749 §4.1.2.1) are stripped too, and they
    # do not even need the query-matching gap to reach a victim:
    # registration is unauthenticated, so an attacker registers their own
    # client_id with a redirect_uri pointing at a LEGITIMATE client's
    # callback carrying `?error=…`. §4.1.2 makes `error` and `code`
    # mutually exclusive, so client libraries branch on `error` first —
    # the victim consents, a code is minted, and the client throws it
    # away. Worse, `error_description` is rendered as UI copy and
    # `error_uri` as a "more information" link, both attacker-written,
    # inside the real client's trusted error surface. That is a phishing
    # primitive on a flow the user actually approved.
    RESPONSE_PARAMS = %w[code state iss error error_description error_uri].freeze

    def build_redirect_uri(base_uri, code:, state:)
      uri = URI.parse(base_uri)
      query_params = URI.decode_www_form(uri.query || "")
                        .reject { |key, _| RESPONSE_PARAMS.include?(key) }
      query_params << [ "code", code ]
      query_params << [ "state", state ] if state.present?
      query_params << [ "iss", issuer_url ]
      uri.query = URI.encode_www_form(query_params)
      uri.to_s
    end

    # Action Controller's ordinary redirect helper emits the complete Location
    # through `redirect_to.action_controller`; Rails' log subscriber then
    # writes the one-time authorization code in plaintext. The destination has
    # already passed exact registered-URI validation, so construct the 302
    # directly and keep the credential out of redirect instrumentation.
    def redirect_with_authorization_code(location)
      response.headers["Cache-Control"] = "no-store"
      response.headers["Pragma"] = "no-cache"
      response.headers["Location"] = location
      head :found
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
