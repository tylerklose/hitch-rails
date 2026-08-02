# frozen_string_literal: true

module Hitch
  module MCP
    # Declarative MCP tool descriptor. Registry admission, listing, and later
    # execution resolve the current named subclass; instances are never needed.
    class Tool
      NOT_SET = Object.new.freeze
      INVALID_DECLARATION = Object.new.freeze

      class << self
        def inherited(subclass)
          super
          subclass.instance_variable_set(:@tool_name, nil)
          subclass.instance_variable_set(:@description, nil)
          subclass.instance_variable_set(:@input_schema, nil)
          subclass.instance_variable_set(:@output_schema, nil)
          subclass.instance_variable_set(:@annotations, nil)
        end

        def tool_name(value = NOT_SET)
          return @tool_name if value.equal?(NOT_SET)

          @tool_name = copy_declaration(value)
        end

        def description(value = NOT_SET)
          return @description if value.equal?(NOT_SET)

          @description = copy_declaration(value)
        end

        def input_schema(value = NOT_SET, **keywords)
          return @input_schema if value.equal?(NOT_SET) && keywords.empty?

          @input_schema = copy_declaration(combine_value_and_keywords(value, keywords))
        end

        def output_schema(value = NOT_SET, **keywords)
          return @output_schema if value.equal?(NOT_SET) && keywords.empty?

          @output_schema = copy_declaration(combine_value_and_keywords(value, keywords))
        end

        def annotations(value = NOT_SET, **keywords)
          return @annotations if value.equal?(NOT_SET) && keywords.empty?

          @annotations = copy_declaration(combine_value_and_keywords(value, keywords))
        end

        # Coarse request-local admission. Host applications must opt each tool
        # in explicitly; argument-aware authorization remains a later gate.
        def available_to?(_context)
          false
        end

        # Framework-owned until M4 installs argument policy and host behavior.
        # Registry validation rejects any subclass that replaces this boundary.
        def call(arguments:, context:)
          raise "MCP tool execution is unavailable in this development milestone"
        end

        private

        def combine_value_and_keywords(value, keywords)
          return keywords unless keywords.empty?
          return value unless value.equal?(NOT_SET)

          INVALID_DECLARATION
        end

        def copy_declaration(value, seen = {})
          case value
          when Hash
            return INVALID_DECLARATION if seen.key?(value.object_id)

            seen[value.object_id] = true
            copied = {}
            value.each do |key, child|
              normalized_key = declaration_key(key)
              return INVALID_DECLARATION if normalized_key.equal?(INVALID_DECLARATION)
              return INVALID_DECLARATION if copied.key?(normalized_key)

              copied[normalized_key] = copy_declaration(child, seen)
            end
            copied.freeze
          when Array
            return INVALID_DECLARATION if seen.key?(value.object_id)

            seen[value.object_id] = true
            value.map { |child| copy_declaration(child, seen) }.freeze
          when String
            value.dup.freeze
          when Symbol, Numeric, TrueClass, FalseClass, NilClass
            value
          else
            INVALID_DECLARATION
          end
        ensure
          seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
        end

        def declaration_key(value)
          return value.dup.freeze if value.is_a?(String)
          return value if value.is_a?(Symbol)

          INVALID_DECLARATION
        end
      end

      private_constant :NOT_SET, :INVALID_DECLARATION
    end
  end
end
