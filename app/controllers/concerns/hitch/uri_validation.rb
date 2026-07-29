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
      return false if parsed.host.blank?
      # RFC 6749 §3.1.2: the redirection endpoint URI MUST NOT include a
      # fragment component. Enforced because redirect_uri_matches? does
      # not compare fragments either, so one would otherwise ride through
      # unvalidated — and a client that scans location.hash for response
      # parameters (a real pattern in libraries supporting both query and
      # fragment response modes) would read whatever was smuggled there.
      return false if parsed.fragment.present?

      case parsed.scheme
      when "https" then true
      when "http"  then loopback_host?(parsed.host)
      else false
      end
    rescue URI::InvalidURIError
      false
    end

    def loopback_host?(host)
      host == "localhost" || host == "127.0.0.1"
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

      return false if reg.fragment.present? || inb.fragment.present?
      return false if reg.userinfo.present? || inb.userinfo.present?
      return false unless reg.scheme == inb.scheme
      return false unless reg.host == inb.host
      return false unless reg.path == inb.path
      return false unless reg.query == inb.query

      return true if reg.scheme == "http" && loopback_host?(reg.host)

      reg.port == inb.port
    rescue URI::InvalidURIError
      false
    end

    # RFC 8707 §2: `resource` parameter MUST be an absolute URI as
    # specified by Section 4.3 of RFC 3986. MUST NOT include a fragment
    # component. Schemes other than http/https don't make sense as MCP
    # server audiences.
    def valid_resource_uri?(uri)
      parsed = URI.parse(uri)
      return false unless parsed.absolute?
      return false unless %w[http https].include?(parsed.scheme)
      return false if parsed.host.blank?
      return false if parsed.fragment.present?

      true
    rescue URI::InvalidURIError
      false
    end
  end
end
