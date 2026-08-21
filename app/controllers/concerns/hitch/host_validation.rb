# frozen_string_literal: true

require "uri"

module Hitch
  # Rejects an untrusted request origin before an engine endpoint derives
  # issuer URLs, parses OAuth credentials, or performs registration work.
  module HostValidation
    extend ActiveSupport::Concern

    included do
      # This must precede host authentication and every callback that can
      # derive a public URL from the request. `prepend` keeps that ordering
      # even when a host includes Hitch into a controller that already has
      # application-wide before_actions.
      prepend_before_action :require_allowed_hitch_host!
    end

    private

    def require_allowed_hitch_host!
      return if hitch_request_origin_allowed?

      render json: {
        error: "invalid_request",
        error_description: "Request origin is not allowed"
      }, status: :bad_request
    end

    def hitch_request_origin_allowed?
      request_host = request.hostname.to_s.downcase
      return false if request_host.empty?

      resource = URI.parse(Hitch.configuration.resource_uri.to_s)
      hitch_allowed_hosts(resource).include?(request_host) &&
        request.scheme == resource.scheme &&
        request.port == resource.port
    rescue URI::InvalidURIError
      false
    end

    def hitch_allowed_hosts(resource = URI.parse(Hitch.configuration.resource_uri.to_s))
      explicit_hosts = Hitch.configuration.allowed_hosts
      canonical_host = resource.hostname&.downcase

      [ canonical_host, *explicit_hosts ].compact.uniq
    rescue URI::InvalidURIError
      explicit_hosts
    end
  end
end
