# frozen_string_literal: true

require "mcp"

module Hitch
  module MCP
    module Internal
      # Reports only a synthetic failure with fixed structural context, then
      # returns the same generic tool error for every non-explicit failure.
      class ErrorNormalizer
        GENERIC_TOOL_ERROR = "Tool execution failed"
        SOURCE = "hitch.mcp.tool"
        TOOL_NAME_PATTERN = /\A[A-Za-z0-9_.-]{1,64}\z/
        PHASE_CATEGORIES = {
          context: "context_handoff",
          arguments: "argument_normalization",
          authorization: "argument_policy",
          execution: "host_execution",
          result: "result_normalization"
        }.freeze

        class ReportedFailure < StandardError
          def initialize
            super("Hitch MCP tool execution failed")
          end
        end

        class << self
          def call(error:, phase:, context:, tool_name:)
            report(error:, phase:, tool_name:) unless expected_denial?(error, phase)
            generic_response
          rescue StandardError, SystemStackError
            generic_response
          end

          private

          def expected_denial?(error, phase)
            phase == :authorization && error.is_a?(Forbidden)
          end

          def report(error:, phase:, tool_name:)
            return unless Rails.respond_to?(:error)

            reported_failure = ReportedFailure.new
            reported_failure.set_backtrace(caller(1, 8))
            reported_failure.freeze
            Rails.error.report(
              reported_failure,
              handled: true,
              severity: :error,
              context: reporting_context(error:, phase:, tool_name:),
              source: SOURCE
            )
          end

          def reporting_context(error:, phase:, tool_name:)
            category = ResultNormalizer.failure_category(error) || PHASE_CATEGORIES.fetch(phase, "tool_boundary")
            context = { hitch_mcp_category: category.to_s.freeze }
            if tool_name.instance_of?(String) && TOOL_NAME_PATTERN.match?(tool_name)
              context[:hitch_mcp_tool] = tool_name.dup.freeze
            end
            request_id = Observation.__send__(:current_request_id)
            context[:hitch_mcp_request_id] = request_id.dup.freeze if request_id
            context.freeze
          end

          def generic_response
            ::MCP::Tool::Response.new(
              [ { type: "text", text: GENERIC_TOOL_ERROR } ],
              error: true
            )
          end
        end

        private_constant :ReportedFailure
      end
    end
  end
end
