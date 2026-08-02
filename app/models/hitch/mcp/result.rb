# frozen_string_literal: true

module Hitch
  module MCP
    # Closed host return value for MCP tool execution. Constructors copy host
    # values so later mutation cannot change the result Hitch validates.
    class Result
      class << self
        def text(value)
          new(:text, copy_string(value), nil)
        end

        def structured(value, text: nil)
          copied_text = text.nil? ? nil : copy_string(text)
          new(:structured, copy_json(value), copied_text)
        rescue SystemStackError
          raise ArgumentError, "MCP Result nesting is too deep"
        end

        def error(public_message)
          new(:error, copy_string(public_message), nil)
        end

        private

        def copy_string(value)
          raise ArgumentError, "MCP Result text must be a String" unless value.is_a?(String)

          value.dup.freeze
        end

        def copy_json(value, seen = {})
          copied = case value
          when Hash
            raise ArgumentError, "MCP Result contains a recursive value" if seen.key?(value.object_id)

            seen[value.object_id] = true
            value.each_with_object({}) do |(key, child), result|
              raise ArgumentError, "MCP Result keys must be Strings" unless key.is_a?(String)
              raise ArgumentError, "MCP Result contains a duplicate key" if result.key?(key)

              result[key.dup.freeze] = copy_json(child, seen)
            end
          when Array
            raise ArgumentError, "MCP Result contains a recursive value" if seen.key?(value.object_id)

            seen[value.object_id] = true
            value.map { |child| copy_json(child, seen) }
          when String
            value.dup
          when Float
            raise ArgumentError, "MCP Result contains a non-finite number" unless value.finite?

            value
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            raise ArgumentError, "MCP Result must contain only JSON values"
          end
          copied.freeze
        ensure
          seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
        end
      end

      def initialize(kind, value, text)
        @kind = kind
        @value = value
        @text = text
        freeze
      end

      private

      attr_reader :kind, :value, :text

      private_class_method :new, :allocate
    end
  end
end
