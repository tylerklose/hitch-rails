# frozen_string_literal: true

require "test_helper"
require "hitch/mcp/test_helper"
require "json"

class Hitch::MCPTestHelperTest < ActiveSupport::TestCase
  Configuration = Data.define(:resource_uri)
  CapturedRequest = Data.define(:path, :body, :headers)

  class Harness
    include Hitch::MCP::TestHelper

    attr_reader :captured_request

    def post(path, params:, headers:)
      @captured_request = CapturedRequest.new(path:, body: params, headers:)
    end

    def response
      :ordinary_integration_response
    end
  end

  setup do
    @helper = Harness.new
  end

  test "mcp_headers returns the exact modern call headers for the current resource" do
    with_resource("https://tools.example.test:8443/mcp") do
      headers = @helper.mcp_headers(
        token: "test-token_123",
        method: "tools/call",
        name: "billing.lookup"
      )

      assert_equal(
        {
          "Host" => "tools.example.test:8443",
          "Authorization" => "Bearer test-token_123",
          "Content-Type" => "application/json",
          "Accept" => "application/json, text/event-stream",
          "MCP-Protocol-Version" => "2026-07-28",
          "Mcp-Method" => "tools/call",
          "Mcp-Name" => "billing.lookup"
        },
        headers
      )
    end
  end

  test "mcp_headers resolves IPv6 and default ports without leaking into a body" do
    with_resource("https://[::1]/mcp") do
      headers = @helper.mcp_headers(token: "abc", method: "tools/list")

      assert_equal "[::1]", headers.fetch("Host")
      assert_equal "Bearer abc", headers.fetch("Authorization")
      refute_includes JSON.generate(headers.except("Authorization")), "abc"
      refute_includes headers, "Mcp-Name"
    end
  end

  test "header inputs reject malformed bearer method name and protocol values" do
    with_resource("https://tools.example.test/mcp") do
      invalid_calls = [
        -> { @helper.mcp_headers(token: "has space", method: "tools/list") },
        -> { @helper.mcp_headers(token: "abc", method: "resources/list") },
        -> { @helper.mcp_headers(token: "abc", method: "tools/call") },
        -> { @helper.mcp_headers(token: "abc", method: "tools/list", name: "unexpected") },
        -> { @helper.mcp_headers(token: "abc", method: "tools/call", name: "bad name") },
        -> { @helper.mcp_headers(token: "abc", method: "tools/list", protocol_version: "2026-99-99") },
        -> { @helper.mcp_headers(token: "abc", method: "tools/list", protocol_version: "2026-213") }
      ]

      invalid_calls.each { |call| assert_raises(ArgumentError, &call) }
    end
  end

  test "post_mcp builds one copied final envelope and returns the ordinary response" do
    original_params = {
      name: "billing.lookup",
      arguments: { account_id: "account-1", flags: [ true, nil ] }
    }
    capabilities = { tools: { listChanged: false } }
    client_info = { name: "host-test", version: "1.0" }

    result = with_resource("https://tools.example.test:8443/custom/mcp?profile=test") do
      @helper.post_mcp(
        method: "tools/call",
        token: "token-123",
        params: original_params,
        id: 7,
        capabilities:,
        client_info:
      )
    end

    request = @helper.captured_request
    body = JSON.parse(request.body)
    assert_equal :ordinary_integration_response, result
    assert_equal "/custom/mcp?profile=test", request.path
    assert_equal [ "jsonrpc", "id", "method", "params" ], body.keys
    assert_equal [ "2.0", 7, "tools/call" ], body.values_at("jsonrpc", "id", "method")
    assert_equal "billing.lookup", body.dig("params", "name")
    assert_equal "account-1", body.dig("params", "arguments", "account_id")
    assert_equal capabilities.deep_stringify_keys,
      body.dig("params", "_meta", "io.modelcontextprotocol/clientCapabilities")
    assert_equal client_info.deep_stringify_keys,
      body.dig("params", "_meta", "io.modelcontextprotocol/clientInfo")
    assert_equal "billing.lookup", request.headers.fetch("Mcp-Name")
    assert_equal "Bearer token-123", request.headers.fetch("Authorization")
    refute_includes request.body, "token-123"
    assert_equal(
      {
        name: "billing.lookup",
        arguments: { account_id: "account-1", flags: [ true, nil ] }
      },
      original_params
    )
  end

  test "post_mcp omits absent client info and rejects ambiguous or non-JSON inputs" do
    with_resource("https://tools.example.test/mcp") do
      @helper.post_mcp(method: "tools/list", token: "abc")
      body = JSON.parse(@helper.captured_request.body)
      metadata = body.dig("params", "_meta")

      refute_includes metadata, "io.modelcontextprotocol/clientInfo"
      assert_equal({}, metadata.fetch("io.modelcontextprotocol/clientCapabilities"))

      recursive = {}
      recursive["self"] = recursive
      invalid_calls = [
        -> { @helper.post_mcp(method: "tools/list", token: "abc", params: []) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", params: { _meta: {} }) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", params: { "a" => 1, a: 2 }) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", params: recursive) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", capabilities: []) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", client_info: []) },
        -> { @helper.post_mcp(method: "tools/list", token: "abc", id: nil) }
      ]
      invalid_calls.each { |call| assert_raises(ArgumentError, &call) }
    end
  end

  test "each helper call reads the current configured resource" do
    with_resource("http://127.0.0.1:3001/first") do
      assert_equal "127.0.0.1:3001", @helper.mcp_headers(token: "abc", method: "tools/list").fetch("Host")
      @helper.post_mcp(method: "tools/list", token: "abc")
      assert_equal "/first", @helper.captured_request.path
    end

    with_resource("https://second.example.test/mcp") do
      assert_equal "second.example.test", @helper.mcp_headers(token: "abc", method: "tools/list").fetch("Host")
      @helper.post_mcp(method: "tools/list", token: "abc")
      assert_equal "/mcp", @helper.captured_request.path
    end
  end

  private

  def with_resource(uri)
    replacement = -> { Configuration.new(resource_uri: uri) }
    stub_class_method(Hitch, :configuration, replacement) { yield }
  end
end
