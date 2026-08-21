# frozen_string_literal: true

require "mcp"

module Hitch
  module MCP
    # Declarative MCP tool descriptor. Registry admission, listing, and later
    # execution resolve the current named subclass; instances are never needed.
    class Tool
      # A tool subclass is written in the host's own namespace, so these two
      # siblings would otherwise be spelled Hitch::MCP:: on every line that
      # does anything. Naming them here puts them on the subclass's ancestor
      # chain, where Ruby's constant lookup finds them unqualified. Same
      # objects: `rescue Hitch::MCP::Forbidden` still catches `raise Forbidden`.
      Result = Hitch::MCP::Result
      Forbidden = Hitch::MCP::Forbidden

      NOT_SET = Object.new.freeze
      INVALID_DECLARATION = Object.new.freeze
      ARGUMENT_MESSAGES = {
        recursive: "recursive MCP tool arguments",
        key: "MCP tool argument keys must be strings",
        duplicate_key: "duplicate MCP tool argument key",
        non_finite: "MCP tool arguments contain a non-finite number",
        foreign: "MCP tool arguments must contain only JSON values"
      }.freeze

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
          invocation&.result_normalized!(kind: result.kind)
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

        def normalize_arguments(value)
          Internal::JsonValues.copy(
            value,
            keys: :stringify_symbols, symbols: :reject, foreign: :reject,
            finite: true, duplicates: :reject, freeze: true,
            on_invalid: ->(reason, _detail) { raise ArgumentError, ARGUMENT_MESSAGES.fetch(reason) }
          )
        end

        # The setter path guards against value and keywords both being absent,
        # so one of the two is always present here.
        def combine_value_and_keywords(value, keywords)
          keywords.empty? ? value : keywords
        end

        def copy_declaration(value)
          Internal::JsonValues.copy(
            value,
            keys: :preserve, foreign: :reject, duplicates: :reject, freeze: true,
            on_invalid: ->(_reason, _detail) { INVALID_DECLARATION }
          )
        end
      end

      private_constant :NOT_SET, :INVALID_DECLARATION, :ARGUMENT_MESSAGES
    end
  end
end
