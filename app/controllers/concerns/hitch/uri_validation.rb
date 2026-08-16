# frozen_string_literal: true

module Hitch
  # Shared OAuth URI validation rules used by both the authorization
  # endpoint (per-request `redirect_uri`) and the DCR endpoint
  # (`redirect_uris` array at registration time).
  #
  # Without DCR-time validation, an attacker could register a client
  # with `javascript:alert(1)` or `http://attacker.test/cb` and then
  # try to use it at authorize — RFC 7591 §2 makes URI policy the
  # authorization server's responsibility.
  module UriValidation
    extend ActiveSupport::Concern

    private

    # Authorization redirect URI: https everywhere except loopback
    # http (which RFC 8252 permits for native apps).
    def valid_redirect_uri?(uri)
      parsed = URI.parse(uri)
      return false if parsed.hostname.blank?
      return false unless parsed.userinfo.nil? && !userinfo_component_present?(uri)
      # RFC 6749 §3.1.2: the redirection endpoint URI MUST NOT include a
      # fragment component. Enforced because redirect_uri_matches? does
      # not compare fragments either, so one would otherwise ride through
      # unvalidated — and a client that scans location.hash for response
      # parameters (a real pattern in libraries supporting both query and
      # fragment response modes) would read whatever was smuggled there.
      return false unless parsed.fragment.nil?

      case parsed.scheme
      when "https" then true
      when "http"  then loopback_host?(parsed.hostname)
      else false
      end
    rescue URI::InvalidURIError
      false
    end

    def loopback_host?(host)
      Hitch::ResourceUri::LOOPBACK_HOSTS.include?(host)
    end

    def userinfo_component_present?(value)
      Hitch::ResourceUri.userinfo_component_present?(value)
    end

    # Exact comparison, with exactly one exception.
    #
    # RFC 9700 §4.1.3 and MCP 2026-07-28 ("Authorization servers MUST
    # validate exact redirect URIs against pre-registered values") both
    # require the inbound redirect_uri to match a registered one exactly.
    # RFC 8252 §7.3 grants a single carve-out: a native app using a
    # loopback redirect MAY pick an ephemeral port per session, so the
    # PORT — and only the port — may differ there. Claude Code relies on
    # this.
    #
    # The query string is compared. Skipping it meant a caller could
    # append parameters a client's callback reads (`next`, `returnTo`, a
    # tenant selector) to a registration that never contained them, and
    # — before those parameters were stripped downstream — shadow the
    # OAuth response parameters outright. Stripping remains in place as
    # defense in depth; this is the control.
    #
    # Fragments and userinfo are refused on both sides. Neither is
    # comparable in any meaningful way, RFC 6749 §3.1.2 forbids a
    # fragment on a redirection endpoint, and a userinfo component would
    # let `https://evil%40x:pw@claude.ai/cb` match a registration of
    # `https://claude.ai/cb`.
    def redirect_uri_matches?(registered, inbound)
      reg = URI.parse(registered)
      inb = URI.parse(inbound)

      return false unless reg.fragment.nil? && inb.fragment.nil?
      return false unless reg.userinfo.nil? && inb.userinfo.nil?
      return false if userinfo_component_present?(registered) || userinfo_component_present?(inbound)
      return false unless reg.scheme == inb.scheme
      return false unless reg.hostname == inb.hostname
      return false unless reg.path == inb.path
      return false unless reg.query == inb.query

      return true if reg.scheme == "http" && loopback_host?(reg.hostname)

      reg.port == inb.port
    rescue URI::InvalidURIError
      false
    end

    # RFC 8707 audience binding, shared by the authorize and token
    # endpoints: the request's `resource` must canonicalize to exactly
    # the resource this server is configured to protect. Returns the
    # canonical resource string, or nil after rendering the OAuth error.
    def require_canonical_resource(value)
      if value.blank?
        oauth_error("invalid_target", "resource is required")
        return nil
      end

      allow_loopback = Rails.env.local?
      requested = Hitch::ResourceUri.canonicalize!(value, allow_loopback_http: allow_loopback)
      configured = Hitch::ResourceUri.canonicalize!(
        Hitch.configuration.resource_uri,
        allow_loopback_http: allow_loopback
      )
      unless requested == configured
        oauth_error("invalid_target", "resource does not identify this MCP server")
        return nil
      end

      requested
    rescue Hitch::ResourceUri::Invalid => error
      oauth_error("invalid_target", error.message)
      nil
    end
  end
end
