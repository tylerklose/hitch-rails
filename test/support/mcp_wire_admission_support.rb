# frozen_string_literal: true

# The dummy MCP controller only runs real rate-limit admission when
# X-Hitch-Wire-Admission: runtime is sent — a test hook of the dummy app,
# not a gem feature, which is why it stays out of the public
# Hitch::MCP::TestHelper: a headers: merge there would let callers override
# the exact headers the helper exists to validate.
module McpWireAdmissionSupport
  PROTOCOL_VERSION = "2026-07-28"

  def post_admitted_mcp(method:, token:, name: nil, arguments: {}, id: SecureRandom.hex(4))
    post "/mcp",
      params: request_body(method:, name:, arguments:, id:),
      headers: admission_headers(token:, method:, name:)
  end

  def admission_headers(token:, method:, name: nil)
    {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => PROTOCOL_VERSION,
      "Mcp-Method" => method,
      "X-Hitch-Wire-Admission" => "runtime"
    }.tap do |headers|
      headers["Mcp-Name"] = name if name
    end
  end

  # Rack-env spelling for call_app_with_input, which merges straight into a
  # raw env. Content-Type is dropped: its env key is CONTENT_TYPE, not
  # HTTP_CONTENT_TYPE, and call_app_with_input sets it itself.
  def admission_env(token:, method:, name: nil)
    admission_headers(token:, method:, name:)
      .except("Content-Type")
      .transform_keys { |header| "HTTP_#{header.upcase.tr("-", "_")}" }
  end

  def request_body(method:, name: nil, arguments: {}, id: SecureRandom.hex(4))
    params = {
      "_meta" => {
        "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientCapabilities" => {}
      }
    }
    if method == "tools/call"
      params["name"] = name
      params["arguments"] = arguments
    end
    JSON.generate(jsonrpc: "2.0", id:, method:, params:)
  end
end
