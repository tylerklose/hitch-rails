# frozen_string_literal: true

# A REAL host /mcp endpoint: a genuine ::MCP::Server (official `mcp` SDK,
# a test-only dependency) wired through Hitch::ServerEndpoint. Unlike
# McpTestController — which simulates handle_json's return contract — this
# exercises the actual SDK output, so the 202/200 Streamable HTTP
# response shaping is verified against what `mcp` really returns, not an
# assumption about it. This is the regression guard for the Grok bug.
#
# MCP constants are referenced inside the action (lazily) so the class
# loads even though `mcp` is only present in the test group.
class RealMcpController < ApplicationController
  include Hitch::ServerEndpoint
  before_action :require_mcp_token!

  def create
    render_mcp_response(mcp_server.handle_json(request.raw_post))
  end

  private

  def mcp_server
    echo = MCP::Tool.define(
      name: "echo",
      description: "Echoes its input back.",
      input_schema: { type: "object", properties: { text: { type: "string" } } }
    ) do |text: "", server_context: nil|
      MCP::Tool::Response.new([ { type: "text", text: text } ])
    end
    MCP::Server.new(name: "hitch-dummy", version: "0.0.1", tools: [ echo ])
  end
end
