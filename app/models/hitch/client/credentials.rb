# frozen_string_literal: true

module Hitch
  class Client
    class Credentials
      class SerializationForbidden < TypeError; end

      attr_reader :client, :client_secret

      def initialize(client:, client_secret:)
        @client = client
        @client_secret = client_secret.to_s.dup.freeze
        freeze
      end

      def inspect
        %(#<#{self.class.name} client_id=#{client.client_id.inspect} client_secret="[FILTERED]">)
      end

      alias_method :to_s, :inspect

      def to_h(*)
        raise SerializationForbidden, "one-time client credentials cannot be serialized"
      end

      def as_json(*) = to_h
      def to_json(*) = to_h
    end
  end
end
