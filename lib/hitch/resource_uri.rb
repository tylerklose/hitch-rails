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
      canonical.port = nil if default_port?(canonical)
      canonical.to_s
    rescue URI::InvalidURIError
      raise Invalid, "resource must be an absolute HTTP URI"
    end

    def self.default_port?(uri)
      (uri.scheme == "https" && uri.port == 443) || (uri.scheme == "http" && uri.port == 80)
    end
    private_class_method :default_port?

    # URI.parse can miss a userinfo component that a raw scan of the
    # authority still finds; callers use both checks together.
    def self.userinfo_component_present?(value)
      authority = value.to_s.match(/\A[a-z][a-z0-9+.-]*:\/\/([^\/?#]*)/i)&.captures&.first
      authority&.include?("@") || false
    end
  end
end
