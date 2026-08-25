# frozen_string_literal: true

module Hitch
  # Client authentication for the endpoints a machine calls with its own
  # credentials (RFC 6749 §3.2.1): one resolver and one error mapping,
  # with each endpoint naming the challenge realm it answers under.
  module ClientResolution
    extend ActiveSupport::Concern

    included do
      rescue_from Hitch::ClientAuthentication::Invalid do |error|
        if error.http_status == :unauthorized
          response.headers["WWW-Authenticate"] = %(Basic realm="#{client_authentication_realm}")
        end
        oauth_error(error.oauth_code, error.message, error.http_status)
      end
    end

    private

    def resolved_client_id(oauth)
      resolved_client_authentication(oauth).client_id
    end

    def resolved_client_authentication(oauth)
      Hitch::ClientAuthentication.resolve(
        request: request,
        body_client_id: oauth[:client_id],
        body_secret_present: oauth[:client_secret].present?
      )
    end
  end
end
