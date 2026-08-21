# frozen_string_literal: true

require "base64"
require "date"
require "digest"
require "json"
require "securerandom"
require "uri"

module Hitch
  module MCP
    module TestHelper
      # Public: host test suites pin this. Spelled out rather than read from
      # Internal::Protocol, which lives in app/models and is not loaded when a
      # host requires this file before booting Rails. A test asserts the two
      # never drift.
      PROTOCOL_VERSION = "2026-07-28"

      TOKEN_PATTERN = /\A[A-Za-z0-9\-._~+\/]+=*\z/

      def mcp_headers(token:, method:, name: nil, protocol_version: PROTOCOL_VERSION)
        resource = mcp_test_resource_uri!
        mcp_test_headers(
          resource:,
          token:,
          method:,
          name:,
          protocol_version:
        )
      end

      def post_mcp(method:, token:, params: {}, id: "hitch-test", client_info: nil,
        capabilities: {}, protocol_version: PROTOCOL_VERSION)
        resource = mcp_test_resource_uri!
        normalized_params = mcp_test_json_hash(params, "params")
        raise ArgumentError, "params must not supply _meta" if normalized_params.key?("_meta")

        normalized_capabilities = mcp_test_json_hash(capabilities, "capabilities")
        normalized_client_info = if client_info.nil?
          nil
        else
          mcp_test_json_hash(client_info, "client_info")
        end
        normalized_id = mcp_test_id(id)
        name = normalized_params["name"] if method == "tools/call"
        metadata = {
          "io.modelcontextprotocol/protocolVersion" => protocol_version.to_s,
          "io.modelcontextprotocol/clientCapabilities" => normalized_capabilities
        }
        if normalized_client_info
          metadata["io.modelcontextprotocol/clientInfo"] = normalized_client_info
        end
        normalized_params["_meta"] = metadata
        body = JSON.generate(
          "jsonrpc" => "2.0",
          "id" => normalized_id,
          "method" => method,
          "params" => normalized_params
        )

        post resource.request_uri,
          params: body,
          headers: mcp_test_headers(
            resource:,
            token:,
            method:,
            name:,
            protocol_version:
          )
        response
      rescue JSON::GeneratorError, EncodingError => error
        raise ArgumentError, "MCP test request is not valid JSON: #{error.class}"
      end

      # Mints a real access token through the production authorization-code
      # path (create_authorization! + PKCE exchange) and returns the raw
      # bearer token post_mcp expects. The principal is any persisted record
      # the host treats as the signed-in user.
      def mint_mcp_token(principal:, scopes: Hitch.configuration.supported_scopes,
        client_id: "hitch-test-client")
        scopes = Array(scopes)
        unsupported = scopes - Hitch.configuration.supported_scopes
        unless unsupported.empty?
          # The real flow clamps grants to supported_scopes; minting past it
          # would let a test pass against a grant production can never issue.
          raise ArgumentError,
            "scopes are not in Hitch.configuration.supported_scopes: #{unsupported.join(' ')}"
        end

        verifier = SecureRandom.urlsafe_base64(64)
        challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
        resource_uri = Hitch.configuration.resource_uri
        authorization = Hitch::AccessToken.create_authorization!(
          principal: principal,
          client_id: client_id,
          client_name: client_id,
          code_challenge: challenge,
          code_challenge_method: "S256",
          scopes: scopes.join(" "),
          resource_uri: resource_uri
        )
        Hitch::AccessToken.exchange_authorization_code!(
          raw_code: authorization.raw_authorization_code,
          code_verifier: verifier,
          client_id: client_id,
          resource_uri: resource_uri
        ).fetch(:raw_token)
      end

      private

      def mcp_test_resource_uri!
        value = Hitch.configuration.resource_uri
        raise ArgumentError, "Hitch resource_uri must be configured" unless value.is_a?(String)

        resource = URI.parse(value)
        unless %w[http https].include?(resource.scheme) && resource.host && !resource.fragment
          raise ArgumentError, "Hitch resource_uri must be an absolute HTTP URI"
        end

        resource
      rescue URI::InvalidURIError
        raise ArgumentError, "Hitch resource_uri must be an absolute HTTP URI"
      end

      def mcp_test_headers(resource:, token:, method:, name:, protocol_version:)
        mcp_test_validate_token!(token)
        mcp_test_validate_method_and_name!(method, name)
        mcp_test_validate_protocol_version!(protocol_version)

        {
          "Host" => Hitch::ResourceUri.authority(resource),
          "Authorization" => "Bearer #{token}",
          "Content-Type" => "application/json",
          "Accept" => "application/json, text/event-stream",
          "MCP-Protocol-Version" => protocol_version,
          "Mcp-Method" => method
        }.tap do |headers|
          headers["Mcp-Name"] = name if name
        end
      end

      def mcp_test_validate_token!(token)
        return if token.is_a?(String) && token.bytesize.between?(1, 4_096) &&
          TOKEN_PATTERN.match?(token)

        raise ArgumentError, "token must be a bounded bearer token"
      end

      def mcp_test_validate_method_and_name!(method, name)
        raise ArgumentError, "method is not a supported Hitch MCP method" unless
          Internal::Protocol::METHODS.include?(method)

        if method == "tools/call"
          raise ArgumentError, "name is required for tools/call" unless
            Internal::Protocol.tool_name?(name)
        elsif !name.nil?
          raise ArgumentError, "name is only valid for tools/call"
        end
      end

      def mcp_test_validate_protocol_version!(protocol_version)
        raise ArgumentError, "protocol_version must be an ISO date" unless
          protocol_version.is_a?(String) && protocol_version.match?(/\A\d{4}-\d{2}-\d{2}\z/)

        Date.iso8601(protocol_version)
      rescue Date::Error
        raise ArgumentError, "protocol_version must be an ISO date"
      end

      def mcp_test_id(id)
        return id.dup if id.is_a?(String) && !id.empty?
        return id if id.is_a?(Integer)

        raise ArgumentError, "id must be a nonempty String or Integer"
      end

      # A generate/parse round trip is the JSON normalizer: symbol keys
      # become strings, structures are deep-copied so the caller's hash is
      # never mutated, and cycles or non-finite numbers raise.
      def mcp_test_json_hash(value, label)
        raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)

        JSON.parse(JSON.generate(value))
      rescue JSON::JSONError
        raise ArgumentError, "#{label} is not plain JSON data"
      end

      private_constant :TOKEN_PATTERN
    end
  end
end
