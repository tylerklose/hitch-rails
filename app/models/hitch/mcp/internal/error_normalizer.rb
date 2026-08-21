# frozen_string_literal: true

require "mcp"

module Hitch
  module MCP
    module Internal
      # Reports only a synthetic failure with fixed structural context, then
      # returns the same generic tool error for every non-explicit failure.
      class ErrorNormalizer
        SOURCE = "hitch.mcp.tool"
        PHASE_CATEGORIES = {
          context: "context_handoff",
          arguments: "argument_normalization",
          authorization: "argument_policy",
          execution: "host_execution",
          result: "result_normalization"
        }.freeze

        class << self
          def call(error:, phase:, context:, tool_name:)
            unless expected_denial?(error, phase)
              report(error:, phase:, tool_name:)
              log_local_diagnosis(error:, phase:, tool_name:)
            end
            generic_response
          rescue StandardError, SystemStackError
            generic_response
          end

          private

          def expected_denial?(error, phase)
            phase == :authorization && error.is_a?(Forbidden)
          end

          def log_local_diagnosis(error:, phase:, tool_name:)
            category = ResultNormalizer.failure_category(error)
            LocalDiagnosis.report(
              "MCP tool #{tool_name.inspect} failed during #{phase}#{" (#{category})" if category}",
              error
            )
          end

          def report(error:, phase:, tool_name:)
            SanitizedReport.emit(
              source: SOURCE,
              message: "Hitch MCP tool execution failed",
              context: reporting_context(error:, phase:, tool_name:)
            )
          end

          def reporting_context(error:, phase:, tool_name:)
            category = ResultNormalizer.failure_category(error) || PHASE_CATEGORIES.fetch(phase, "tool_boundary")
            context = { hitch_mcp_category: category.to_s.freeze }
            if Protocol.tool_name?(tool_name)
              context[:hitch_mcp_tool] = tool_name.dup.freeze
            end
            request_id = Observation.current_request_id
            context[:hitch_mcp_request_id] = request_id.dup.freeze if request_id
            context.freeze
          end

          def generic_response
            ::MCP::Tool::Response.new(
              [ { type: "text", text: Protocol::GENERIC_TOOL_ERROR } ],
              error: true
            )
          end
        end
      end
    end
  end
end
