# frozen_string_literal: true

module Hitch
  module MCP
    # Closed host return value for MCP tool execution. Constructors copy host
    # values so later mutation cannot change the result Hitch validates.
    class Result
      RESULT_MESSAGES = {
        recursive: "MCP Result contains a recursive value",
        key: "MCP Result keys must be Strings or Symbols",
        duplicate_key: "MCP Result contains a duplicate key",
        non_finite: "MCP Result contains a non-finite number",
        foreign: "MCP Result must contain only JSON values"
      }.freeze
      private_constant :RESULT_MESSAGES

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

        def copy_json(value)
          Internal::JsonValues.copy(
            value,
            # Symbols are how Ruby spells a JSON string. Anything else outside
            # JSON is refused, never as_json'd: a model would leak every column.
            keys: :stringify_symbols, symbols: :to_s, foreign: :reject, finite: true,
            duplicates: :reject, freeze: true,
            on_invalid: ->(reason, _detail) { raise ArgumentError, RESULT_MESSAGES.fetch(reason) }
          )
        end
      end

      attr_reader :kind, :value, :text

      def initialize(kind, value, text)
        @kind = kind
        @value = value
        @text = text
        freeze
      end

      private_class_method :new, :allocate
    end
  end
end
