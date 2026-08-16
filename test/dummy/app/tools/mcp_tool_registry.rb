# frozen_string_literal: true

class McpToolRegistry < Hitch::MCP::Registry
  register McpTools::Echo, scopes: [ "mcp" ]
end
