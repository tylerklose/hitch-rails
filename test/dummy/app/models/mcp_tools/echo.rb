# frozen_string_literal: true

module McpTools
  class Echo < Hitch::MCP::Tool
    tool_name "dummy.echo"
    description "Describe the dummy application's registered echo tool"
    input_schema(
      type: "object",
      properties: {
        message: { type: "string", maxLength: 1_000 }
      },
      required: [ "message" ],
      additionalProperties: false
    )
    annotations read_only_hint: true,
      destructive_hint: false,
      idempotent_hint: true,
      open_world_hint: false
  end
end
