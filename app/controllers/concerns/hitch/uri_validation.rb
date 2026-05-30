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

    # RFC 8252 §7.3: native apps using loopback redirects MAY pick an
    # ephemeral port per session, so the registered URI's port and the
    # inbound URI's port don't have to match. Claude Code does this.
    # Non-loopback URIs must match exactly (scheme + host + port +
    # path).
    def redirect_uri_matches?(registered, inbound)
      reg = URI.parse(registered)
      inb = URI.parse(inbound)
      return false unless reg.scheme == inb.scheme && reg.host == inb.host
      return false unless reg.path == inb.path

      if reg.scheme == "http" && loopback_host?(reg.host)
        # Loopback: port-agnostic per RFC 8252.
        true
      else
        reg.port == inb.port
      end
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
