# frozen_string_literal: true

module Hitch
  module MCP
    # Request-local authority envelope used only by the hard-coded M2 slice.
    # M3 replaces this staged value with the public Hitch::MCP::Context.
    class SliceContext
      attr_reader :principal, :access_token, :client_id, :resource, :request_id,
        :protocol_version, :meta

      def initialize(principal:, access_token:, client_id:, resource:, request_id:, protocol_version:, meta:)
        @principal = principal
        @access_token = access_token
        @client_id = client_id.dup.freeze
        @resource = resource.dup.freeze
        @request_id = copy_scalar(request_id)
        @protocol_version = protocol_version.dup.freeze
        @meta = deep_copy_and_freeze(meta)
        freeze
      end

      private

      def copy_scalar(value)
        value.is_a?(String) ? value.dup.freeze : value
      end

      def deep_copy_and_freeze(value)
        copy = case value
        when Hash
          value.to_h { |key, child| [ key.to_s.dup.freeze, deep_copy_and_freeze(child) ] }
        when Array
          value.map { |child| deep_copy_and_freeze(child) }
        when String
          value.dup
        else
          value
        end
        copy.freeze
      end
    end

    private_constant :SliceContext
  end
end
