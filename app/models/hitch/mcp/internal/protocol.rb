# frozen_string_literal: true

module Hitch
  module MCP
    module Internal
      # The MCP protocol vocabulary: the one place that says which version
      # Hitch speaks, which methods it answers, and what a tool may be named.
      #
      # These facts are read by the request verifier, the SDK adapter and its
      # response normalizer, the registry, the tool error path, observation,
      # and the host-facing test helper. Each used to carry its own copy, and
      # the copies had begun to disagree — two spellings of the tool-name rule
      # were in circulation, one of them enforcing length separately. A single
      # home is what makes the next version bump one edit instead of a search.
      module Protocol
        VERSION = "2026-07-28"

        # Every JSON-RPC method the endpoint answers. Anything else is
        # -32601 before the SDK is built.
        METHODS = %w[server/discover tools/list tools/call].freeze

        # The wire name of a tool: 1-64 ASCII letters, digits, underscore,
        # dot, or dash. Also the shape any tool name must have before it may
        # appear in a telemetry payload or an error report.
        MAX_TOOL_NAME_LENGTH = 64
        TOOL_NAME = /\A[A-Za-z0-9_.-]{1,#{MAX_TOOL_NAME_LENGTH}}\z/

        # The only tool failure text that reaches a client when the host did
        # not author one itself.
        GENERIC_TOOL_ERROR = "Tool execution failed"

        module_function

        # instance_of?, not is_a?: a String subclass can override the
        # methods every downstream reader calls, and a tool name reaches
        # telemetry payloads and error reports. The strict test is the one
        # the reporting boundary already required, so it is the only one.
        def tool_name?(value)
          value.instance_of?(String) && TOOL_NAME.match?(value)
        end
      end
    end
  end
end
