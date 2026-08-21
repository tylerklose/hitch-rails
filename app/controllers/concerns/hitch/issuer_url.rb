# frozen_string_literal: true

require "uri"

module Hitch
  # The authorization server's issuer identifier (RFC 8414 §2).
  #
  # Shared because it MUST be byte-identical everywhere it appears. The
  # discovery document advertises it as `issuer`; the authorization response
  # carries it as `iss` (RFC 9207); bearer challenges point back to it. Clients
  # compare these values exactly.
  #
  # The issuer is the fixed origin of the canonical resource_uri. It never
  # comes from Host or Forwarded headers. `allowed_hosts` are ingress aliases,
  # not alternate issuer identities; every accepted alias advertises this same
  # canonical origin.
  module IssuerUrl
    extend ActiveSupport::Concern

    private

    def issuer_url
      resource = URI.parse(Hitch.configuration.resource_uri.to_s)
      hostname = resource.hostname
      host = hostname.include?(":") ? "[#{hostname}]" : hostname
      default_port = resource.scheme == "https" ? 443 : 80
      port = resource.port == default_port ? "" : ":#{resource.port}"

      "#{resource.scheme}://#{host}#{port}"
    end
  end
end
