# frozen_string_literal: true

module Hitch
  # The authorization server's issuer identifier (RFC 8414 §2).
  #
  # Shared because it MUST be byte-identical everywhere it appears. The
  # discovery document advertises it as `issuer`; the authorization
  # response carries it as `iss` (RFC 9207). Clients compare the two with
  # an exact string comparison and refuse to exchange the authorization
  # code on any mismatch — the Ruby MCP SDK does precisely this in
  # `MCP::Client::OAuth::Flow#validate_authorization_response_issuer!`.
  # Two independent `request.base_url` calls would agree today and drift
  # the first time one of them grew a suffix.
  #
  # `request.base_url` honors X-Forwarded-* when the host has set
  # `config.action_dispatch.trusted_proxies` correctly — important behind
  # reverse proxies (Kamal, Fly, Heroku) where the raw host is the
  # internal container address.
  module IssuerUrl
    extend ActiveSupport::Concern

    private

    def issuer_url
      request.base_url
    end
  end
end
