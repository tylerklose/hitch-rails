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
        REQUEST_ID_PATTERN = /\A[A-Za-z0-9_.:-]{1,128}\z/
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
            report(error:, phase:, context:, tool_name:) unless expected_denial?(error, phase)
            generic_response
          rescue StandardError, SystemStackError
            generic_response
          end

          private

          def expected_denial?(error, phase)
            phase == :authorization && error.is_a?(Hitch::MCP::Forbidden)
          end

          def report(error:, phase:, context:, tool_name:)
            return unless Rails.respond_to?(:error)

            category = ResultNormalizer.failure_category(error) || PHASE_CATEGORIES.fetch(phase, "tool_boundary")
            report_context = {
              hitch_mcp_category: category.to_s.freeze
            }
            if tool_name.is_a?(String) && TOOL_NAME_PATTERN.match?(tool_name)
              report_context[:hitch_mcp_tool] = tool_name.dup.freeze
            end
            request_id = context.request_id if context.is_a?(Hitch::MCP::Context)
            if request_id.is_a?(String) && REQUEST_ID_PATTERN.match?(request_id)
              report_context[:hitch_mcp_request_id] = request_id.dup.freeze
            end

            reported_failure = ReportedFailure.new
            reported_failure.set_backtrace(caller(1, 8))
            reported_failure.freeze
            Rails.error.report(
              reported_failure,
              handled: true,
              severity: :error,
              context: report_context.freeze,
              source: SOURCE
            )
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
