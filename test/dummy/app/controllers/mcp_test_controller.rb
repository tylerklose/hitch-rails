# frozen_string_literal: true

# Minimal stand-in for a host's MCP endpoint, used to exercise
# Hitch::ServerEndpoint. A real host hands the body to
# ::MCP::Server#handle_json; here we simulate only its return contract so
# a test failure points unambiguously at the concern, not at the mcp gem:
# a JSON-RPC request (has "id") yields a JSON string, a notification (no
# "id") yields nil.
class McpTestController < ApplicationController
  include Hitch::ServerEndpoint
  before_action :require_mcp_token!

  def create
    body = parse_body
    result =
      if body["id"]
        { jsonrpc: "2.0", id: body["id"], result: { ok: true } }.to_json
      end
    render_mcp_response(result)
  end

  private

  def parse_body
    JSON.parse(request.raw_post)
  rescue JSON::ParserError
    {}
  end
end
