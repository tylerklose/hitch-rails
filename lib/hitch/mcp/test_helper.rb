# frozen_string_literal: true

require "date"
require "json"
require "uri"

module Hitch
  module MCP
    module TestHelper
      PROTOCOL_VERSION = "2026-07-28"
      METHODS = %w[server/discover tools/list tools/call].freeze
      TOOL_NAME_PATTERN = /\A[A-Za-z0-9_.-]{1,64}\z/
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
          "Host" => mcp_test_authority(resource),
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
        raise ArgumentError, "method is not a supported Hitch MCP method" unless METHODS.include?(method)

        if method == "tools/call"
          raise ArgumentError, "name is required for tools/call" unless
            name.is_a?(String) && TOOL_NAME_PATTERN.match?(name)
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

      def mcp_test_authority(resource)
        host = resource.host.include?(":") ? "[#{resource.host.delete_prefix('[').delete_suffix(']')}]" : resource.host
        default_port = resource.scheme == "https" ? 443 : 80
        resource.port == default_port ? host : "#{host}:#{resource.port}"
      end

      def mcp_test_id(id)
        return id.dup if id.is_a?(String) && !id.empty?
        return id if id.is_a?(Integer)

        raise ArgumentError, "id must be a nonempty String or Integer"
      end

      def mcp_test_json_hash(value, label)
        raise ArgumentError, "#{label} must be a Hash" unless value.is_a?(Hash)

        mcp_test_json_copy(value)
      end

      def mcp_test_json_copy(value, seen = {})
        copied = case value
        when Hash
          raise ArgumentError, "recursive MCP test JSON" if seen.key?(value.object_id)

          seen[value.object_id] = true
          value.each_with_object({}) do |(key, child), result|
            normalized_key = case key
            when String then key.dup
            when Symbol then key.to_s
            else raise ArgumentError, "MCP test JSON keys must be Strings or Symbols"
            end
            raise ArgumentError, "duplicate MCP test JSON key" if result.key?(normalized_key)

            result[normalized_key] = mcp_test_json_copy(child, seen)
          end
        when Array
          raise ArgumentError, "recursive MCP test JSON" if seen.key?(value.object_id)

          seen[value.object_id] = true
          value.map { |child| mcp_test_json_copy(child, seen) }
        when String
          value.dup
        when Float
          raise ArgumentError, "MCP test JSON contains a non-finite number" unless value.finite?

          value
        when Integer, TrueClass, FalseClass, NilClass
          value
        else
          raise ArgumentError, "MCP test JSON contains an unsupported value"
        end
        copied
      ensure
        seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
      end

      private_constant :METHODS, :TOKEN_PATTERN, :TOOL_NAME_PATTERN
    end
  end
end
