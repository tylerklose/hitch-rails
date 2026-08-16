# frozen_string_literal: true

require "mcp"

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
        # in explicitly.
        def available_to?(_context)
          false
        end

        # Argument-aware host policy is deny-default. Its return value is not an
        # authority signal: allowing means returning without raising.
        def authorize!(_context, arguments:)
          raise Forbidden
        end

        # Host behavior runs only after availability, static scope, SDK schema,
        # and argument-aware policy have all admitted the invocation.
        def perform(_context, arguments:)
          raise "MCP tool perform must be implemented"
        end

        # This SDK-facing boundary is final. Registry validation rejects any
        # subclass that replaces it, so every invocation follows the same
        # context extraction, argument normalization, policy, host, and Result
        # normalization order.
        def call(server_context:, **sdk_arguments)
          phase = :context
          invocation = nil
          reporting_tool_name = tool_name
          context = server_context.fetch(:hitch_context)
          phase = :arguments
          arguments = normalize_arguments(sdk_arguments)
          invocation = Internal::Observation.start_invocation(tool_name: reporting_tool_name)
          phase = :authorization
          authorize!(context, arguments:)
          invocation&.argument_policy_allowed!
          phase = :execution
          invocation&.execution_started!
          result = perform(context, arguments:)
          phase = :result
          normalized = Internal::ResultNormalizer.call(
            result:,
            output_schema: output_schema,
            max_bytes: Hitch.configuration.mcp.max_result_bytes
          )
          invocation&.result_normalized!(kind: result.__send__(:kind))
          normalized
        rescue StandardError, SystemStackError => error
          invocation&.failed!(
            phase:,
            expected_denial: phase == :authorization && error.is_a?(Hitch::MCP::Forbidden)
          )
          Internal::ErrorNormalizer.call(
            error:,
            phase:,
            context:,
            tool_name: reporting_tool_name
          )
        ensure
          invocation&.finish!
        end

        private

        def normalize_arguments(value, seen = {})
          normalized = case value
          when Hash
            raise ArgumentError, "recursive MCP tool arguments" if seen.key?(value.object_id)

            seen[value.object_id] = true
            value.each_with_object({}) do |(key, child), result|
              normalized_key = case key
              when String then key.dup.freeze
              when Symbol then key.to_s.freeze
              else raise ArgumentError, "MCP tool argument keys must be strings"
              end
              raise ArgumentError, "duplicate MCP tool argument key" if result.key?(normalized_key)

              result[normalized_key] = normalize_arguments(child, seen)
            end
          when Array
            raise ArgumentError, "recursive MCP tool arguments" if seen.key?(value.object_id)

            seen[value.object_id] = true
            value.map { |child| normalize_arguments(child, seen) }
          when String
            value.dup
          when Float
            raise ArgumentError, "MCP tool arguments contain a non-finite number" unless value.finite?

            value
          when Integer, TrueClass, FalseClass, NilClass
            value
          else
            raise ArgumentError, "MCP tool arguments must contain only JSON values"
          end
          normalized.freeze
        ensure
          seen.delete(value.object_id) if value.is_a?(Hash) || value.is_a?(Array)
        end

        # The setter path guards against value and keywords both being absent,
        # so one of the two is always present here.
        def combine_value_and_keywords(value, keywords)
          keywords.empty? ? value : keywords
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
