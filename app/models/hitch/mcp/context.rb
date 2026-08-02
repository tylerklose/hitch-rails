# frozen_string_literal: true

module Hitch
  module MCP
    # Frozen, request-local authority envelope passed to host MCP policy and
    # behavior. Host and Active Record references are intentionally preserved
    # as opaque references; freezing this envelope does not claim to freeze
    # those objects.
    class Context
      attr_reader :principal, :access_token, :scope, :granted_scopes, :client_id,
        :resource, :request_id, :remote_ip, :user_agent, :protocol_version, :meta

      def initialize(
        principal:,
        access_token:,
        scope:,
        granted_scopes:,
        client_id:,
        resource:,
        request_id:,
        remote_ip:,
        user_agent:,
        protocol_version:,
        meta:
      )
        raise ArgumentError, "principal is required" if principal.nil?
        raise ArgumentError, "access_token is required" if access_token.nil?

        @principal = principal
        @access_token = access_token
        @scope = scope
        @granted_scopes = copy_scopes(granted_scopes)
        @client_id = copy_required_string(client_id, "client_id")
        @resource = copy_required_string(resource, "resource")
        @request_id = copy_request_id(request_id)
        @remote_ip = copy_required_string(remote_ip, "remote_ip")
        @user_agent = copy_optional_string(user_agent, "user_agent")
        @protocol_version = copy_required_string(protocol_version, "protocol_version")
        @meta = copy_meta(meta)
        freeze
      end

      private

      def copy_scopes(values)
        raise ArgumentError, "granted_scopes must be an Array" unless values.is_a?(Array)

        values.map do |value|
          copy_required_string(value, "granted_scopes entries")
        end.freeze
      end

      def copy_request_id(value)
        unless value.is_a?(String) || value.is_a?(Numeric)
          raise ArgumentError, "request_id must be a String or Numeric"
        end

        value.is_a?(String) ? value.dup.freeze : value
      end

      def copy_required_string(value, name)
        unless value.is_a?(String) && !value.empty?
          raise ArgumentError, "#{name} must be a nonempty String"
        end

        value.dup.freeze
      end

      def copy_optional_string(value, name)
        return if value.nil?

        raise ArgumentError, "#{name} must be a String or nil" unless value.is_a?(String)

        value.dup.freeze
      end

      def copy_meta(value)
        raise ArgumentError, "meta must be a Hash" unless value.is_a?(Hash)

        deep_copy_json(value)
      end

      def deep_copy_json(value)
        copy = case value
        when Hash
          value.to_h do |key, child|
            raise ArgumentError, "meta keys must be Strings" unless key.is_a?(String)

            [ key.dup.freeze, deep_copy_json(child) ]
          end
        when Array
          value.map { |child| deep_copy_json(child) }
        when String
          value.dup
        when Numeric, TrueClass, FalseClass
          value
        else
          raise ArgumentError, "meta must contain only JSON values" unless value.nil?
        end
        copy.freeze
      end
    end
  end
end
