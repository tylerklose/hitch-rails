# frozen_string_literal: true

require "uri"

module Hitch
  class ResourceUri
    class Invalid < ArgumentError; end

    LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze

    def self.canonicalize!(value, allow_loopback_http: false)
      uri = URI.parse(value.to_s)
      scheme = uri.scheme.to_s.downcase
      host = uri.hostname.to_s.downcase

      raise Invalid, "resource must be an absolute HTTP URI" unless uri.absolute? && host.present?
      unless uri.userinfo.nil? && !userinfo_component_present?(value)
        raise Invalid, "resource must not include userinfo"
      end
      raise Invalid, "resource must not include a fragment" unless uri.fragment.nil?
      unless scheme == "https" || (scheme == "http" && allow_loopback_http && LOOPBACK_HOSTS.include?(host))
        raise Invalid, "resource must use HTTPS"
      end

      canonical = uri.dup
      canonical.scheme = scheme
      canonical.hostname = host
      canonical.port = nil if canonical.port == canonical.default_port
      canonical.to_s
    rescue URI::InvalidURIError
      raise Invalid, "resource must be an absolute HTTP URI"
    end

    # The `host[:port]` authority, with the port omitted when it is the
    # scheme's default. URI already brackets IPv6 literals in #host and
    # already knows each scheme's default port, so neither rule is restated
    # here or at any call site.
    def self.authority(uri)
      uri.port == uri.default_port ? uri.host : "#{uri.host}:#{uri.port}"
    end

    # The origin (RFC 6454): scheme and authority, no path, query, or
    # fragment. The authorization server's issuer identifier is the origin of
    # the canonical resource_uri (RFC 8414 §2), and it MUST be byte-identical
    # in the discovery document, the `iss` authorization response parameter
    # (RFC 9207), and every bearer challenge. One derivation is what makes
    # that true by construction rather than by convention.
    def self.origin(uri)
      "#{uri.scheme}://#{authority(uri)}"
    end

    # The path-aware protected-resource metadata URL (RFC 9728 §3.1): the
    # well-known segment sits between the origin and the resource's own path.
    # Derives its own origin so a caller cannot pair this path with a
    # different issuer.
    def self.protected_resource_metadata_url(uri)
      path = uri.path.to_s
      suffix = path.empty? || path == "/" ? "" : path
      query = uri.query ? "?#{uri.query}" : ""

      "#{origin(uri)}/.well-known/oauth-protected-resource#{suffix}#{query}"
    end

    # URI.parse can miss a userinfo component that a raw scan of the
    # authority still finds; callers use both checks together.
    def self.userinfo_component_present?(value)
      authority = value.to_s.match(/\A[a-z][a-z0-9+.-]*:\/\/([^\/?#]*)/i)&.captures&.first
      authority&.include?("@") || false
    end
  end
end
