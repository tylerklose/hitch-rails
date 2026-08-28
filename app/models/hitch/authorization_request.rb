# frozen_string_literal: true

module Hitch
  # The HTTP-free core of one authorize request: parameter and PKCE
  # validation, client and redirect_uri resolution against whichever
  # registration scheme the client_id belongs to, scope clamping, and
  # response-redirect construction. The controller renders what this
  # object decides.
  class AuthorizationRequest
    include Hitch::IssuerUrl
    include Hitch::UriValidation

    Error = Data.define(:code, :description, :status)

    # Response parameters are stripped from the registered query before the
    # response is appended. Defense in depth plus one real gap: a client that
    # legitimately registered a query containing a response parameter would
    # otherwise receive it twice, and first-wins query parsers (URLSearchParams,
    # Go's Query().Get, Python's parse_qs) would read the registered value —
    # the issuer mix-up RFC 9207 exists to prevent. The error parameters don't
    # even need that gap: registration is unauthenticated, so an attacker can
    # point their own client's redirect_uri at a legitimate client's callback
    # carrying `?error=…`, and §4.1.2 makes clients branch on `error` first —
    # attacker-written UI copy inside the real client's trusted error surface.
    RESPONSE_PARAMS = %w[code state iss error error_description error_uri].freeze

    attr_reader :params, :principal

    def initialize(params, principal:)
      @params = params
      @principal = principal
    end

    def valid?
      @error = validate unless defined?(@error)
      @error.nil?
    end

    def error
      valid?
      @error
    end

    # :decision is accepted on the consent POST but never echoed by the
    # consent screen — a crafted authorize link must not pre-press Deny.
    def deny?
      params[:decision] == "deny"
    end

    def client_id = params[:client_id]
    def redirect_uri = params[:redirect_uri]
    def state = params[:state]
    def code_challenge = params[:code_challenge]
    def code_challenge_method = params[:code_challenge_method]

    # The canonical resource (RFC 8707 audience), available once valid.
    attr_reader :resource

    # The resolved client, from whichever registration scheme the client_id
    # belongs to: an https client_id is a Client ID Metadata Document
    # reference (MCP 2026-07-28); anything else is an opaque DCR client_id.
    # The two cannot collide. Resolved once — each question the flow asks
    # (redirect validation, consent warning, audit name) would otherwise
    # repeat the DB lookup or, for CIMD without a shared cache, the outbound
    # fetch. nil (no such client) memoizes too.
    def client
      return @client if defined?(@client)

      @client =
        if ClientIdMetadata.reference?(client_id)
          # A principal that cannot be counted must not drive outbound
          # fetches: the per-actor limit is the bound on amplification, so
          # no actor means no fetch and the client reads as unknown.
          actor = rate_limit_actor
          actor && ClientIdMetadata.resolve(client_id, actor: actor)
        else
          Client.find_by(client_id: client_id)
        end
    end

    # Intersect the requested scope with the server's supported_scopes
    # allowlist. A client can only ever receive scopes the server actually
    # supports (RFC 6749 §3.3 — the AS MAY narrow). An empty intersection
    # falls back to the default scope so the token is never scopeless.
    def granted_scopes
      Hitch.configuration.clamp_scopes(params[:scope])
    end

    # The redirect back to the validated redirect_uri, carrying `iss`
    # unconditionally (RFC 9207 — byte-identical to the discovery issuer,
    # which is why both come from the shared IssuerUrl derivation).
    def redirect_uri_for(**response)
      uri = URI.parse(redirect_uri)
      query_params = URI.decode_www_form(uri.query || "")
                        .reject { |key, _| RESPONSE_PARAMS.include?(key) }
      response.merge(iss: issuer_url).each do |key, value|
        query_params << [ key.to_s, value ] if value.present?
      end
      uri.query = URI.encode_www_form(query_params)
      uri.to_s
    end

    def redirect_host
      parsed = URI.parse(redirect_uri.to_s)
      scheme = parsed.scheme.to_s.downcase
      return parsed.host if scheme == "https" || scheme == "http"

      native_voucher_identity
    rescue URI::InvalidURIError
      nil
    end

    # The consent screen's display name. Never the client's declared name —
    # that is attacker-controllable in both registration schemes. https
    # (and loopback http) labels come from the verified redirect host;
    # a native scheme labels the voucher (CIMD document host, or the
    # scheme itself), never an attacker-chosen URI host like `mcp`.
    def display_client_name
      friendly_client_name || redirect_host || "An application"
    end

    # The name the client claims for itself. Attacker-controllable in both
    # schemes; persisted on the token for audit fidelity only.
    def audit_client_name
      client&.client_name || friendly_client_name || "Unknown"
    end

    # MCP 2026-07-28 security considerations: a metadata document "cannot
    # prevent localhost URL impersonation by itself" — anyone can host a
    # document claiming any name and point it at a loopback port, and nothing
    # proves which program is listening there. The consent screen warns.
    def localhost_only_client?
      return false unless ClientIdMetadata.reference?(client_id)

      declared = registered_redirect_uris
      return false if declared.blank?

      declared.all? { |candidate| loopback_http_uri?(candidate) }
    end

    private

    def validate
      return invalid_request("response_type is required") if params[:response_type].blank?
      unless params[:response_type] == "code"
        return failure("unsupported_response_type", "response_type must be code")
      end
      return invalid_request("client_id is required") if client_id.blank?
      return invalid_request("redirect_uri is required") if redirect_uri.blank?
      return invalid_request("Invalid redirect_uri") unless valid_redirect_uri?(redirect_uri)
      return invalid_request("code_challenge is required") if code_challenge.blank?
      unless Hitch::Pkce.valid_s256_challenge?(code_challenge)
        return invalid_request("code_challenge must be a 43-character S256 value")
      end
      unless code_challenge_method == "S256"
        return invalid_request("code_challenge_method must be S256")
      end

      resource_error = validate_resource
      return resource_error if resource_error

      @params = params.merge(resource: @resource).freeze
      validate_client_redirect
    end

    # RFC 8707 audience binding: the request's `resource` must canonicalize
    # to exactly the resource this server protects.
    def validate_resource
      return failure("invalid_target", "resource is required") if params[:resource].blank?

      allow_loopback = Rails.env.local?
      requested = Hitch::ResourceUri.canonicalize!(params[:resource], allow_loopback_http: allow_loopback)
      configured = Hitch::ResourceUri.canonicalize!(
        Hitch.configuration.resource_uri,
        allow_loopback_http: allow_loopback
      )
      unless requested == configured
        return failure("invalid_target", "resource does not identify this MCP server")
      end

      @resource = requested
      nil
    rescue Hitch::ResourceUri::Invalid => error
      failure("invalid_target", error.message)
    end

    # redirect_uri MUST be validated against a registered client on EVERY
    # authorize request (OAuth 2.1 §4.1.1, RFC 9700 §4.1.3). There is no
    # unregistered path: clients without prior registration obtain a
    # client_id via DCR or host a metadata document first.
    def validate_client_redirect
      registered = registered_redirect_uris
      return failure("invalid_client", unknown_client_message) if registered.nil?
      return invalid_request("client has no usable redirect_uris") if registered.blank?

      # RFC 8252 port-agnostic match for loopback; exact otherwise.
      return nil if registered.any? { |candidate| redirect_uri_matches?(candidate, redirect_uri) }

      invalid_request("redirect_uri not registered for this client")
    end

    # The client's declared redirect_uris. nil means "no such client"; an
    # empty array means "a client, but nothing usable to redirect to".
    # Shape (https, loopback http, allowlisted native) and who may use a
    # native scheme (CIMD voucher or operator) apply here for every
    # registration scheme — DCR enforces self-registration at mint time,
    # but a metadata document never passes through registration, and a
    # row already in the table must not keep a scheme the client is not
    # vouched for.
    def registered_redirect_uris
      declared = client&.redirect_uris
      return declared if declared.nil?

      declared.select { |candidate| usable_redirect_uri?(candidate) }
    end

    def unknown_client_message
      if ClientIdMetadata.reference?(client_id)
        "Could not resolve a client metadata document at that client_id"
      else
        "Unknown client_id — register via /oauth/register first"
      end
    end


    # Identifies the principal driving a metadata fetch, for per-actor rate
    # limiting — the bound on amplification no DNS or URL trick changes.
    def rate_limit_actor
      Hitch::RateLimitStore.actor_for(principal)
    end

    def usable_redirect_uri?(uri)
      return false unless valid_redirect_uri?(uri)

      parsed = URI.parse(uri)
      scheme = parsed.scheme.to_s.downcase
      return true if scheme == "https" || scheme == "http"

      native_redirect_authorized?(scheme)
    rescue URI::InvalidURIError
      false
    end

    def native_redirect_authorized?(scheme)
      return true if client.is_a?(Hitch::Client) && client.operator_registered?
      return false unless ClientIdMetadata.reference?(client_id)

      Hitch.configuration.vouches_for_native_redirect?(scheme, URI.parse(client_id).hostname)
    rescue URI::InvalidURIError
      false
    end

    # CIMD: the document URL host. Operator / DCR: the scheme. Never the
    # redirect_uri host of a custom scheme — that slot is attacker-chosen.
    def native_voucher_identity
      if ClientIdMetadata.reference?(client_id)
        URI.parse(client_id).hostname
      else
        URI.parse(redirect_uri.to_s).scheme
      end
    rescue URI::InvalidURIError
      nil
    end

    def friendly_client_name
      Hitch.configuration.client_label(redirect_host)
    end

    def invalid_request(description)
      failure("invalid_request", description)
    end

    def failure(code, description)
      Error.new(code: code, description: description, status: :bad_request)
    end
  end
end
