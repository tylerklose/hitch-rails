# frozen_string_literal: true

require "uri"

module Hitch
  module MCP
    module Internal
      # Bearer token extraction and the WWW-Authenticate challenges the
      # endpoint issues (RFC 6750 §3, RFC 9728 protected-resource metadata).
      module BearerChallenge
        MAX_BEARER_TOKEN_BYTES = 512

        module_function

        def token(authorization)
          authorization = authorization.to_s
          return if authorization.bytesize > MAX_BEARER_TOKEN_BYTES + 7
          return unless authorization.valid_encoding?
          return if authorization.match?(/[\u0000-\u001F\u007F-\u009F]/)

          match = authorization.match(/\ABearer ([A-Za-z0-9_-]{1,#{MAX_BEARER_TOKEN_BYTES}})\z/i)
          match && match[1]
        end

        # A generic 401 starts the least-privilege authorization flow with the
        # host's base/default scope. Protected-resource metadata still
        # advertises the complete supported set, and a known available tool
        # names its complete static requirement in a later 403 step-up.
        def challenge(issuer_url:)
          scope = Hitch.configuration.supported_scopes.first
          %(Bearer resource_metadata="#{resource_metadata_url(issuer_url)}", scope="#{scope}")
        end

        def insufficient_scope(required_scopes, issuer_url:)
          "Bearer error=\"insufficient_scope\", " \
            "scope=\"#{required_scopes.join(' ')}\", " \
            "resource_metadata=\"#{resource_metadata_url(issuer_url)}\""
        end

        def resource_metadata_url(issuer_url)
          resource = URI.parse(Hitch.configuration.resource_uri.to_s)
          path = resource.path.to_s
          suffix = path.empty? || path == "/" ? "" : path
          query = resource.query ? "?#{resource.query}" : ""
          "#{issuer_url}/.well-known/oauth-protected-resource#{suffix}#{query}"
        end
      end
    end
  end
end
