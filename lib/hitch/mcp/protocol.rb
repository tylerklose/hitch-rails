# frozen_string_literal: true

module Hitch
  module MCP
    # The MCP protocol vocabulary: the one place that says which version
    # Hitch speaks, which methods it answers, and what a tool may be named.
    #
    # Plain Ruby in lib rather than app/models, because the public test
    # helper reads it at require time, before Rails has booted.
    module Protocol
      VERSION = "2026-07-28"

      # Every JSON-RPC method the endpoint answers. Anything else is -32601
      # before the SDK is built.
      METHODS = %w[server/discover tools/list tools/call].freeze

      # The wire name of a tool, and the shape any tool name must have before
      # it may appear in a telemetry payload or an error report.
      MAX_TOOL_NAME_LENGTH = 64
      TOOL_NAME = /\A[A-Za-z0-9_.-]{1,#{MAX_TOOL_NAME_LENGTH}}\z/

      # The only tool failure text that reaches a client when the host did
      # not author one itself.
      GENERIC_TOOL_ERROR = "Tool execution failed"

      module_function

      # instance_of?, not is_a?: a String subclass can override the methods
      # every downstream reader calls, and a tool name reaches telemetry and
      # error reports.
      def tool_name?(value)
        value.instance_of?(String) && TOOL_NAME.match?(value)
      end
    end
  end
end
