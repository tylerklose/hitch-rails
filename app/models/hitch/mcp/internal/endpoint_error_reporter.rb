# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # Reports an endpoint failure without ever accepting the original
      # exception. Authentication inputs, request bodies, and host state
      # therefore cannot cross this reporting boundary by accident.
      class EndpointErrorReporter
        SOURCE = "hitch.mcp.endpoint"
        CATEGORIES = {
          authentication: "authentication",
          request_admission: "request_admission",
          dispatch: "dispatch"
        }.freeze

        class << self
          def report(category:)
            SanitizedReport.emit(
              source: SOURCE,
              message: "Hitch MCP endpoint failed",
              context: reporting_context(category)
            )
          rescue StandardError, SystemStackError
            nil
          end

          private

          def reporting_context(category)
            context = { hitch_mcp_category: CATEGORIES.fetch(category) }
            request_id = Observation.__send__(:current_request_id)
            context[:hitch_mcp_request_id] = request_id.dup.freeze if request_id
            context.freeze
          end
        end
      end
    end
  end
end
