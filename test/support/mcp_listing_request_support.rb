# frozen_string_literal: true

module McpListingRequestSupport
  MCP_PROTOCOL_VERSION = "2026-07-28"

  def post_listing_mcp(method:, token:, id: "listing-request", name: nil,
    arguments: {}, client_info: :absent, session: self)
    metadata = {
      "io.modelcontextprotocol/protocolVersion" => MCP_PROTOCOL_VERSION,
      "io.modelcontextprotocol/clientCapabilities" => {}
    }
    metadata["io.modelcontextprotocol/clientInfo"] = client_info unless client_info == :absent

    params = { "_meta" => metadata }
    if method == "tools/call"
      params["name"] = name
      params["arguments"] = arguments
    end
    headers = {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => MCP_PROTOCOL_VERSION,
      "Mcp-Method" => method
    }
    headers["Mcp-Name"] = name if name

    session.post "/mcp", params: JSON.generate(
      jsonrpc: "2.0",
      id: id,
      method: method,
      params: params
    ), headers: headers
    session.response
  end
end
