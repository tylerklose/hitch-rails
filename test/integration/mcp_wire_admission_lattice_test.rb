# frozen_string_literal: true

require "test_helper"
require "base64"
require "digest"
require "json"
require "securerandom"

# Rows come from test/lattice/mcp_wire_admission.json (lattice generate
# --seed 42). Expectations come from the specs cited there and the phase order
# in test/contracts/mcp_wire_vectors.yml, never from current behavior.
class MCPWireAdmissionLatticeTest < ActionDispatch::IntegrationTest
  RESOURCE = "https://dummy.test/mcp"
  PROTOCOL_VERSION = "2026-07-28"
  UNSUPPORTED_VERSION = "2099-12-31"
  TOOL_NAME = "hitch.echo"
  SCENARIOS = JSON.parse(Rails.root.join("../lattice/mcp_wire_admission_scenarios.json").read).fetch("scenarios").freeze

  PHASES = %i[parse envelope meta headers method dispatch].freeze
  FAULT_PHASES = {
    "malformed_utf8" => :parse, "truncated_json" => :parse,
    "id_null" => :envelope, "id_absent" => :envelope, "id_fractional" => :envelope,
    "id_object" => :envelope, "jsonrpc_wrong" => :envelope,
    "meta_string" => :meta, "meta_array" => :meta, "meta_missing_protocol" => :meta,
    "method_header_mismatched" => :headers, "name_header_mismatched" => :headers,
    "name_header_invalid_bytes" => :headers, "protocol_unsupported" => :headers
  }.freeze
  RPC_METHODS = {
    "tools_call" => "tools/call", "tools_list" => "tools/list", "server_discover" => "server/discover",
    "resources_list" => "resources/list", "skills_list" => "skills/list"
  }.freeze
  UNDECLARED_METHODS = %w[resources_list skills_list].freeze

  setup do
    Hitch::AccessToken.delete_all
    Hitch::Client.delete_all
    User.delete_all
    Hitch.reset_configuration!
    Hitch.configure do |configuration|
      configuration.resource_uri = RESOURCE
      configuration.allowed_hosts = [ "dummy.test" ]
      configuration.supported_scopes = [ "mcp" ]
      configuration.mcp.registry = "McpToolRegistry"
      configuration.mcp.server_info = { name: "hitch-lattice", version: "0.2.0" }
      configuration.mcp.scope_resolver = ->(principal:, access_token:, request:) { principal }
    end
    McpController.wire_slice_enabled = true
    @user = User.create!(email: "wire-lattice@example.test")
    @token = mint_token
  end

  teardown do
    McpController.wire_slice_enabled = false
    Hitch.reset_configuration!
  end

  test "every generated admission row ends in its earliest failing phase" do
    assert_equal 282, SCENARIOS.length

    failures = SCENARIOS.filter_map do |scenario|
      assert_row(scenario)
      nil
    rescue Minitest::Assertion => error
      error.message
    end
    assert_empty failures, failures.first(10).join("\n\n")
  end

  private

  def assert_row(scenario)
    values = scenario.fetch("values")
    label = "row #{scenario.fetch('id')}: #{values.reject { |_, value| value == 'N/A' }.inspect}"
    id = request_id(values.fetch("id_kind"), scenario.fetch("id"))

    McpController.reset_wire_metrics!
    post "/mcp", params: request_body(values, id), headers: request_headers(values)

    phase, codes = expected_outcome(values)
    assert_operator response.status, :<, 500, label
    assert_equal (phase == :dispatch && values.fetch("method") == "tools_call") ? 1 : 0,
      McpController.wire_metrics[:host], "#{label}: tool execution"
    assert_response_for(phase, codes, values, id, label)
  end

  def expected_outcome(values)
    faults = [ values.fetch("fault"), values.fetch("masked_fault") ].reject { |fault| %w[none N/A].include?(fault) }
    phases = faults.map { |fault| FAULT_PHASES.fetch(fault) }
    phases << :method if UNDECLARED_METHODS.include?(values.fetch("method"))
    phase = phases.min_by { |candidate| PHASES.index(candidate) } || :dispatch
    header_codes = faults.select { |fault| FAULT_PHASES[fault] == :headers }
      .map { |fault| fault == "protocol_unsupported" ? -32022 : -32020 }
    [ phase, phase == :headers ? header_codes.uniq : nil ]
  end

  def assert_response_for(phase, header_codes, values, id, label)
    body = JSON.parse(response.body)
    assert_equal "2.0", body.fetch("jsonrpc"), label

    case phase
    when :parse then assert_error(body, 400, [ -32700 ], nil, label)
    when :envelope then assert_error(body, 400, [ -32600 ], nil, label)
    when :meta then assert_error(body, 400, [ -32602 ], id, label)
    when :headers then assert_error(body, 400, header_codes, id, label)
    when :method then assert_error(body, 404, [ -32601 ], id, label)
    when :dispatch then assert_dispatched(body, values.fetch("method"), id, label)
    end
  end

  def assert_error(body, status, codes, id, label)
    assert_equal status, response.status, label
    assert_includes codes, body.dig("error", "code"), label
    assert_id(id, body, label)
    refute body.key?("result"), label
  end

  def assert_dispatched(body, method, id, label)
    assert_equal 200, response.status, label
    assert_id(id, body, label)
    refute body.key?("error"), label
    result = body.fetch("result")

    case method
    when "tools_call"
      refute result["isError"], label
      assert_equal "text", result.fetch("content").first.fetch("type"), label
    when "tools_list"
      assert_equal [ TOOL_NAME ], result.fetch("tools").map { |tool| tool.fetch("name") }, label
    when "server_discover"
      # Nothing the SDK adds (Skills, subscriptions) is advertised unless Hitch implements it.
      assert_equal({ "tools" => {} }, result.fetch("capabilities"), label)
    end
  end

  # JSON-RPC 2.0 section 5: the response id equals the request id, type included.
  def assert_id(id, body, label)
    assert body.key?("id"), label
    id.nil? ? assert_nil(body["id"], label) : assert_equal(id, body["id"], label)
  end

  def request_id(kind, row)
    case kind
    when "integer" then 1_000 + row
    when "unicode_long" then "  ünï ✓ #{'z' * 200} #{row}"
    else "lattice-#{row}"
    end
  end

  def request_body(values, id)
    method = RPC_METHODS.fetch(values.fetch("method"))
    meta = {
      "io.modelcontextprotocol/protocolVersion" => protocol_version(values),
      "io.modelcontextprotocol/clientCapabilities" => {}
    }
    params = { "_meta" => meta }
    params.merge!("name" => TOOL_NAME, "arguments" => { "message" => "lattice" }) if method == "tools/call"
    body = { "jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params }

    case values.fetch("fault")
    when "id_null" then body["id"] = nil
    when "id_absent" then body.delete("id")
    when "id_fractional" then body["id"] = 1.5
    when "id_object" then body["id"] = { "n" => 1 }
    when "jsonrpc_wrong" then body["jsonrpc"] = "1.0"
    when "meta_string" then params["_meta"] = "meta"
    when "meta_array" then params["_meta"] = []
    when "meta_missing_protocol" then meta.delete("io.modelcontextprotocol/protocolVersion")
    end
    params["_meta"] = [] if values.fetch("masked_fault") == "meta_array"

    raw = JSON.generate(body)
    case values.fetch("fault")
    when "malformed_utf8" then raw.b.sub('"2.0"', "\"2.0\xFF\"".b)
    when "truncated_json" then raw[0...-5]
    else raw
    end
  end

  def request_headers(values)
    method = RPC_METHODS.fetch(values.fetch("method"))
    faults = [ values.fetch("fault"), values.fetch("masked_fault") ]
    headers = {
      "Host" => "dummy.test",
      "Authorization" => "Bearer #{@token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json, text/event-stream",
      "MCP-Protocol-Version" => protocol_version(values),
      "Mcp-Method" => faults.include?("method_header_mismatched") ? (method == "tools/list" ? "tools/call" : "tools/list") : method
    }
    if method == "tools/call"
      headers["Mcp-Name"] =
        if faults.include?("name_header_invalid_bytes") then "#{TOOL_NAME}\xFF".b
        elsif faults.include?("name_header_mismatched") then "hitch.other"
        else TOOL_NAME
        end
    end
    headers
  end

  # Header and body agree on an unsupported version, so only version support fails.
  def protocol_version(values)
    [ values.fetch("fault"), values.fetch("masked_fault") ].include?("protocol_unsupported") ? UNSUPPORTED_VERSION : PROTOCOL_VERSION
  end

  def mint_token
    verifier = SecureRandom.urlsafe_base64(64)
    record = Hitch::AccessToken.create_authorization!(
      principal: @user,
      client_id: "wire-lattice-client",
      client_name: "Wire Lattice Client",
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false),
      code_challenge_method: "S256",
      scopes: "mcp",
      resource_uri: RESOURCE
    )
    exchange_authorization_code(record, verifier: verifier)
  end
end
